import Foundation
import JavaScriptCore
import CommonCrypto
import Security
import Compression

/// 通过 JavaScriptCore 执行洛雪格式音源脚本，内核对齐 lx-music 官方 user-api。
///
/// 官方契约（来自 lx-music-desktop `preload.js` 与移动端「自定义源脚本编写说明」）：
///
/// - 脚本通过 `globalThis.lx` 使用 `EVENT_NAMES`、`on`、`send`、`utils`（buffer/crypto/zlib）、
///   `request`、`currentScriptInfo`、`version`、`env`。
/// - 请求处理器：`lx.on(EVENT_NAMES.request, ({ source, action, info }) => <Promise>)`，
///   处理器**只接收一个对象** `{ source, action, info }` 且**必须返回 Promise**。
///   （桌面端 `preload.js` 也是 `events.request.call(ctx, { source, action, info })` 取返回值。）
/// - 动作名（与内置 musicSdk 一致）：搜索 `music/search`、取链 `music/url`（旧式 `musicUrl`）、
///   歌词 `lyric`、封面 `pic`。`musicUrl` 直接返回 URL 字符串；`lyric` 返回 `{lyric,...}`；
///   `pic` 返回 URL 字符串。
/// - 初始化：`lx.send(EVENT_NAMES.inited, { sources: { kw: { type:'music', actions, qualitys } } })`。
/// - 网络桥：`lx.request(url, { method, headers, body, form, formData, timeout }, (err, resp, body) => ...)`
///   其中 `resp.body` 为响应字符串；也支持无回调时返回 Promise。
///
/// 同时兼容老式 `module.exports = { musicSearch, getMusicUrl, getLyric }`。
///
/// 所有 JS 调用都在主线程执行；网络请求用 URLSession 异步发起，回调派回主线程，
/// 由主线程 RunLoop 泵动处理（不阻塞 UI，也不会死锁）。
final class SourceRuntime {

    private static let eventInited = "inited"
    private static let eventRequest = "request"
    private static let jsEnv = "mobile"
    private static let jsVersion = "2.0.0"

    /// 单个脚本编译后的缓存：老式导出对象 + 洛雪 user-api 桥 + 对应的 lx 对象。
    private struct ScriptEntry {
        var exports: JSValue?
        var requestHandler: JSValue?
        var inited: [String: Any]?
        var lx: JSValue?
    }

    /// 桥接箱：脚本 eval 时 native 闭包往里写 handler / inited。
    private final class BridgeBox {
        var requestHandler: JSValue?
        var inited: [String: Any]?
    }

    private var _context: JSContext?
    private var entries: [String: ScriptEntry] = [:]

    /// 最近一次动作调用的失败原因（脚本异常 / Promise 拒绝 / 回调报错），用于透传给 UI。
    private(set) var lastActionError: String?

    // 定时器注册表（setTimeout / setInterval）
    private var timerRetain: [Int: JSValue] = [:]
    private var timerActive: [Int: Bool] = [:]
    private var nextTimerID = 0

    // MARK: - 公开接口

    func search(source: MusicSource, query: String, page: Int = 1) async -> [Song]? {
        await withCheckedContinuation { cont in
            self.runOnMainAndWait {
                let songs = self.searchOnMain(source: source, query: query, page: page)
                cont.resume(returning: songs)
            }
        }
    }

    func getUrl(source: MusicSource, song: Song) async -> String? {
        await withCheckedContinuation { cont in
            self.runOnMainAndWait {
                let url = self.urlOnMain(source: source, song: song)
                cont.resume(returning: url)
            }
        }
    }

    /// 取链并带回失败原因（脚本异常 / Promise 拒绝内容），供 UI 提示与排障。
    func getUrlWithReport(source: MusicSource, song: Song) async -> (url: String?, error: String?) {
        await withCheckedContinuation { cont in
            self.runOnMainAndWait {
                let url = self.urlOnMain(source: source, song: song)
                cont.resume(returning: (url, url == nil ? self.lastActionError : nil))
            }
        }
    }

    func getLyric(source: MusicSource, song: Song) async -> String? {
        await withCheckedContinuation { cont in
            self.runOnMainAndWait {
                let lyric = self.lyricOnMain(source: source, song: song)
                cont.resume(returning: lyric)
            }
        }
    }

    func getPic(source: MusicSource, song: Song) async -> String? {
        await withCheckedContinuation { cont in
            self.runOnMainAndWait {
                let pic = self.picOnMain(source: source, song: song)
                cont.resume(returning: pic)
            }
        }
    }

    // MARK: - 主线程调度

    private func runOnMainAndWait(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.sync(execute: block)
        }
    }

    // MARK: - JS 上下文与预置环境（必须在主线程调用）

    private func context() -> JSContext {
        if let existing = _context { return existing }
        let ctx = JSContext()!
        ctx.exceptionHandler = { _, exception in
            if let e = exception {
                NSLog("LuoxueMusic JS exception: \(e.toString() ?? "unknown")")
            }
        }
        installPrelude(ctx)
        // 兼容老式脚本的全局同步 request（module.exports 格式用）。
        let requestBlock: @convention(block) (String, JSValue) -> String? = { [weak self] url, optionsValue in
            let options = (optionsValue.toDictionary() as? [String: Any]) ?? [:]
            return self?.syncRequest(url: url, options: options)
        }
        ctx.setObject(requestBlock, forKeyedSubscript: "request" as NSString)
        _context = ctx
        return ctx
    }

    /// 预置 JS 环境：console、定时器、Buffer shim、lx.utils（buffer/crypto/zlib）、lx 工厂。
    private func installPrelude(_ ctx: JSContext) {
        let logBlock: @convention(block) (String) -> Void = { msg in
            NSLog("LuoxueMusic JS log: %@", msg)
        }
        ctx.setObject(logBlock, forKeyedSubscript: "__lx_log" as NSString)

        let timerBlock: @convention(block) (JSValue, Double, Bool) -> Int = { [weak self] fn, ms, repeating in
            guard let self else { return -1 }
            self.nextTimerID += 1
            let id = self.nextTimerID
            self.timerRetain[id] = fn
            self.timerActive[id] = true
            self.scheduleTimer(id: id, fn: fn, delay: max(ms, 0) / 1000.0, repeating: repeating)
            return id
        }
        let timerClearBlock: @convention(block) (Int) -> Void = { [weak self] id in
            self?.timerActive[id] = false
            self?.timerRetain[id] = nil
        }
        ctx.setObject(timerBlock, forKeyedSubscript: "__lx_timer" as NSString)
        ctx.setObject(timerClearBlock, forKeyedSubscript: "__lx_timer_clear" as NSString)

        let md5Block: @convention(block) (JSValue) -> String = { data in
            let bytes = Self.bytesOf(data).map { UInt8($0 & 0xFF) }
            var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
            _ = bytes.withUnsafeBufferPointer { ptr in
                CC_MD5(ptr.baseAddress, CC_LONG(bytes.count), &digest)
            }
            return digest.map { String(format: "%02x", $0) }.joined()
        }
        let sha1Block: @convention(block) (JSValue) -> String = { data in
            let bytes = Self.bytesOf(data).map { UInt8($0 & 0xFF) }
            var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
            _ = bytes.withUnsafeBufferPointer { ptr in
                CC_SHA1(ptr.baseAddress, CC_LONG(bytes.count), &digest)
            }
            return digest.map { String(format: "%02x", $0) }.joined()
        }
        let randomBlock: @convention(block) (Int) -> [Int] = { n in
            var bytes = [UInt8](repeating: 0, count: max(0, min(n, 65536)))
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            return bytes.map { Int($0) }
        }
        ctx.setObject(md5Block, forKeyedSubscript: "__lx_md5" as NSString)
        ctx.setObject(sha1Block, forKeyedSubscript: "__lx_sha1" as NSString)
        ctx.setObject(randomBlock, forKeyedSubscript: "__lx_random" as NSString)

        let cipherBlock: @convention(block) (Bool, JSValue, String, JSValue, JSValue) -> [Int] = { encrypt, data, mode, key, iv in
            Self.runCipher(encrypt: encrypt,
                           data: Self.bytesOf(data),
                           mode: mode,
                           key: Self.bytesOf(key),
                           iv: iv.isUndefined || iv.isNull ? [] : Self.bytesOf(iv))
        }
        ctx.setObject(cipherBlock, forKeyedSubscript: "__lx_cipher" as NSString)

        let rsaBlock: @convention(block) (JSValue, String) -> [Int] = { data, key in
            Self.rsaEncrypt(bytes: Self.bytesOf(data), pemKey: key) ?? []
        }
        ctx.setObject(rsaBlock, forKeyedSubscript: "__lx_rsa" as NSString)

        let inflateBlock: @convention(block) (JSValue) -> [Int] = { data in
            Self.zlibOp(bytes: Self.bytesOf(data), compress: false)
        }
        let deflateBlock: @convention(block) (JSValue) -> [Int] = { data in
            Self.zlibOp(bytes: Self.bytesOf(data), compress: true)
        }
        ctx.setObject(inflateBlock, forKeyedSubscript: "__lx_inflate" as NSString)
        ctx.setObject(deflateBlock, forKeyedSubscript: "__lx_deflate" as NSString)

        ctx.evaluateScript(Self.preludeJS)
    }

    private func scheduleTimer(id: Int, fn: JSValue, delay: Double, repeating: Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.timerActive[id] == true else { return }
            _ = fn.call(withArguments: [])
            if repeating && self.timerActive[id] == true {
                self.scheduleTimer(id: id, fn: fn, delay: delay, repeating: true)
            } else if !repeating {
                self.timerRetain[id] = nil
                self.timerActive[id] = false
            }
        }
    }

    // MARK: - 脚本装载（IIFE 隔离 + 每脚本独立 lx 桥）

    private func prepare(_ ctx: JSContext, source: MusicSource) -> ScriptEntry? {
        if let cached = entries[source.script] {
            if let lx = cached.lx { ctx.setObject(lx, forKeyedSubscript: "lx" as NSString) }
            return cached
        }
        let box = BridgeBox()

        let onHandler: @convention(block) (JSValue) -> Void = { fn in
            box.requestHandler = fn
        }
        let onSend: @convention(block) (String, JSValue) -> Void = { name, data in
            if name == Self.eventRequest { return }
            if name == Self.eventInited {
                box.inited = data.toDictionary() as? [String: Any]
            }
        }
        let request: @convention(block) (String, JSValue, JSValue) -> JSValue? = { [weak self] url, options, callback in
            self?.bridgeRequest(ctx: ctx, url: url, options: options, callback: callback)
        }
        let hooks: [String: Any] = ["onHandler": onHandler, "onSend": onSend, "request": request]

        guard let makeLX = ctx.objectForKeyedSubscript("__lx_makeLX"),
              makeLX.isObject else { return nil }
        let lx = makeLX.call(withArguments: [Self.parseScriptInfo(source.script), hooks])
        guard let lx, lx.isObject else { return nil }
        ctx.setObject(lx, forKeyedSubscript: "lx" as NSString)

        // IIFE 隔离顶层声明，避免多次执行/多音源之间 `const` 冲突。
        let wrapper = """
        (function() {
          var module = { exports: {} };
          var exports = module.exports;
          \(source.script)
          return module.exports;
        })()
        """
        var exportsValue: JSValue?
        if let exports = ctx.evaluateScript(wrapper), exports.isObject, !exports.isNull {
            exportsValue = exports
        }
        let entry = ScriptEntry(exports: exportsValue,
                                requestHandler: box.requestHandler,
                                inited: box.inited,
                                lx: lx)
        guard entry.exports != nil || entry.requestHandler != nil else { return nil }
        entries[source.script] = entry
        return entry
    }

    // MARK: - 调用（老式导出 → 方法；官方格式 → request 处理器）

    private func searchOnMain(source: MusicSource, query: String, page: Int) -> [Song]? {
        let ctx = context()
        guard let entry = prepare(ctx, source: source) else { return nil }
        var raw: Any?
        if let fn = entry.exports?.objectForKeyedSubscript("musicSearch"), isCallable(fn) {
            raw = resolve(fn.call(withArguments: [query, page, 30]))
        } else if entry.requestHandler != nil {
            // 官方动作名 music/search 优先；老式 search / musicSearch 作为短超时候选。
            // （内置平台已承担搜索，这里只是兼容少数支持搜索的桌面版音源，超时给短。）
            let candidates: [(String, TimeInterval)] = [("music/search", 4), ("search", 1), ("musicSearch", 1)]
            for (action, t) in candidates {
                if let r = invokeAction(entry, ctx, platform: source.platform,
                                        action: action,
                                        info: ["searchWord": query, "page": page, "limit": 30],
                                        timeout: t) {
                    raw = r
                    break
                }
            }
        }
        guard raw != nil else { return nil }
        return parseSongs(raw, platform: source.platform)
    }

    /// 从 `send(EVENT_NAMES.inited, { sources: {...} })` 里提取脚本声明的取链动作
    /// （如 'musicUrl' / 'music/url'），没有声明则返回 nil。
    private func declaredUrlActions(_ entry: ScriptEntry) -> Set<String>? {
        guard let sources = entry.inited?["sources"] as? [String: Any] else { return nil }
        var actions: Set<String> = []
        for case let (_, src) in sources {
            guard let srcDict = src as? [String: Any],
                  let list = srcDict["actions"] as? [String] else { continue }
            actions.formUnion(list)
        }
        return actions.isEmpty ? nil : actions
    }

    private func urlOnMain(source: MusicSource, song: Song) -> String? {
        let ctx = context()
        guard let entry = prepare(ctx, source: source) else { return nil }
        lastActionError = nil
        var raw: Any?
        if let fn = entry.exports?.objectForKeyedSubscript("getMusicUrl"), isCallable(fn) {
            raw = resolve(fn.call(withArguments: [song.toSourceInfo()]))
        } else if entry.requestHandler != nil {
            // 按脚本 inited 声明选动作；未声明则按常见顺序尝试。超时给足（取链常含网络往返）。
            let candidates: [(String, TimeInterval)]
            switch declaredUrlActions(entry) {
            case let actions? where actions.contains("musicUrl") && !actions.contains("music/url"):
                candidates = [("musicUrl", 12)]
            case let actions? where actions.contains("music/url") && !actions.contains("musicUrl"):
                candidates = [("music/url", 12)]
            default:
                candidates = [("musicUrl", 10), ("music/url", 10), ("getMusicUrl", 6)]
            }
            for (action, t) in candidates {
                if let r = invokeAction(entry, ctx, platform: source.platform,
                                        action: action,
                                        info: ["type": "128k", "musicInfo": song.toSourceInfo()],
                                        timeout: t) {
                    raw = r
                    break
                }
            }
        }
        return parseUrl(raw)
    }

    private func lyricOnMain(source: MusicSource, song: Song) -> String? {
        let ctx = context()
        guard let entry = prepare(ctx, source: source) else { return nil }
        var raw: Any?
        if let fn = entry.exports?.objectForKeyedSubscript("getLyric"), isCallable(fn) {
            raw = resolve(fn.call(withArguments: [song.toSourceInfo()]))
        } else if entry.requestHandler != nil {
            if let r = invokeAction(entry, ctx, platform: source.platform,
                                    action: "lyric",
                                    info: ["musicInfo": song.toSourceInfo()]) {
                raw = r
            }
        }
        return parseLyric(raw)
    }

    private func picOnMain(source: MusicSource, song: Song) -> String? {
        let ctx = context()
        guard let entry = prepare(ctx, source: source) else { return nil }
        guard entry.requestHandler != nil else { return nil }
        let raw = invokeAction(entry, ctx, platform: source.platform,
                               action: "pic",
                               info: ["musicInfo": song.toSourceInfo()])
        return parseUrl(raw)
    }

    private func isCallable(_ v: JSValue?) -> Bool {
        guard let v, v.isObject else { return false }
        return v.forProperty("call")?.isObject == true
    }

    private func resolve(_ value: JSValue?) -> Any? {
        guard let value else { return nil }
        if value.forProperty("then")?.isObject == true {
            return awaitPromise(value)
        }
        if value.isUndefined || value.isNull { return nil }
        return value.toObject()
    }

    /// 调用洛雪官方 request 处理器。处理器收到单一对象 `{ source, action, info }`，
    /// 既可返回 Promise，也可用第二个参数 `sendResponse(err, data)` 异步回传。
    /// `timeout` 仅用于兜底等待 sendResponse（官方契约以返回 Promise 为主，几乎不会触发）。
    private func invokeAction(_ entry: ScriptEntry, _ ctx: JSContext,
                              platform: String, action: String, info: [String: Any],
                              timeout: TimeInterval = 5) -> Any? {
        guard let handler = entry.requestHandler else { return nil }
        let box = ResultBox()
        let sendResponse: @convention(block) (JSValue, JSValue) -> Void = { err, data in
            guard !box.done else { return }
            box.done = true
            if err.isUndefined || err.isNull || (err.isString && (err.toString() ?? "").isEmpty) {
                box.result = data.toObject()
            } else {
                box.error = err.toString()
            }
        }
        let payload: [String: Any] = ["source": platform, "action": action, "info": info]
        let result = handler.call(withArguments: [payload, sendResponse])
        // 脚本同步抛异常：记录原因并立即返回（不进入 sendResponse 兜底等待）。
        if let exc = ctx.exception {
            lastActionError = "脚本异常: \(exc.toString() ?? "unknown")"
            ctx.exception = nil
            NSLog("LuoxueMusic source action '\(action)' exception: %@", lastActionError ?? "")
            return nil
        }
        // 方式一：处理器返回 Promise / thenable（洛雪官方主路径）。
        if let result, result.forProperty("then")?.isObject == true {
            return awaitPromise(result)
        }
        // 方式二：处理器直接返回非 Promise 值（部分老脚本；官方契约 musicUrl/pic 直接返回 URL 字符串）。
        if let result, !result.isUndefined, !result.isNull {
            return result.toObject()
        }
        // 方式三：等待 sendResponse 回调（非官方但兼容的写法）。动作未处理时会在此短等待后返回 nil。
        var waited: TimeInterval = 0
        while !box.done && waited < timeout {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            waited += 0.05
        }
        if let err = box.error {
            lastActionError = "脚本回调报错: \(err)"
            NSLog("LuoxueMusic source action '\(action)' error: %@", err)
            return nil
        }
        return box.result
    }

    private final class ResultBox {
        var done = false
        var result: Any?
        var error: String?
    }

    // MARK: - 结果解析

    private func parseSongs(_ raw: Any?, platform: String) -> [Song]? {
        let normalized = unwrapActionData(raw)
        if let arr = normalized as? [[String: Any]] {
            return arr.compactMap { song(from: $0, platform: platform) }
        }
        if let dict = normalized as? [String: Any] {
            for key in ["list", "songs", "songList", "data"] {
                if let arr = dict[key] as? [[String: Any]] {
                    return arr.compactMap { song(from: $0, platform: platform) }
                }
                if let inner = dict[key] as? [String: Any], let arr = inner["list"] as? [[String: Any]] {
                    return arr.compactMap { song(from: $0, platform: platform) }
                }
            }
        }
        return nil
    }

    private func song(from dict: [String: Any], platform: String) -> Song? {
        let title = (dict["songname"] as? String) ?? (dict["name"] as? String) ?? (dict["title"] as? String) ?? ""
        let artist = Self.flattenArtist(dict["singer"] ?? dict["artist"] ?? dict["artists"])
        let album = (dict["albumname"] as? String) ?? (dict["albumName"] as? String) ?? (dict["album"] as? String) ?? ""
        let songId = String(describing: dict["songmid"] ?? dict["hash"] ?? dict["id"] ?? dict["songid"] ?? UUID().uuidString)
        let duration = (dict["interval"] as? Int) ?? (dict["duration"] as? Int) ?? 0
        let pic = (dict["img"] as? String) ?? (dict["pic"] as? String) ?? (dict["picUrl"] as? String) ?? (dict["image"] as? String) ?? ""
        let lrc = (dict["lrcUrl"] as? String) ?? (dict["lyricUrl"] as? String) ?? ""
        guard !title.isEmpty else { return nil }
        return Song(source: platform, songId: songId, title: title, artist: artist,
                    album: album, duration: duration, picUrl: pic, lrcUrl: lrc)
    }

    private static func flattenArtist(_ raw: Any?) -> String {
        if let arr = raw as? [[String: Any]] {
            return arr.compactMap { ($0["name"] as? String) }.joined(separator: "、")
        }
        if let arr = raw as? [String] {
            return arr.joined(separator: "、")
        }
        return raw as? String ?? ""
    }

    /// 提取音乐直链：接受字符串、{url}、{data:{url}}、{action,data:{url}}、数组等形态。
    private func parseUrl(_ raw: Any?) -> String? {
        guard let raw else { return nil }
        if let str = raw as? String, !str.isEmpty, str.hasPrefix("http") { return str }
        if let arr = raw as? [Any], let first = arr.first {
            return parseUrl(first)
        }
        if let dict = raw as? [String: Any] {
            let d = unwrapActionData(dict)
            if let dd = d as? [String: Any] {
                for key in ["url", "playUrl", "src", "link"] {
                    if let u = dd[key] as? String, !u.isEmpty, u.hasPrefix("http") { return u }
                }
            }
        }
        return nil
    }

    /// 提取歌词：接受字符串或 {lyric,...}/{data:{lyric}} 形态。
    private func parseLyric(_ raw: Any?) -> String? {
        guard let raw else { return nil }
        if let str = raw as? String, !str.isEmpty { return str }
        if let dict = raw as? [String: Any] {
            let d = unwrapActionData(dict)
            if let dd = d as? [String: Any] {
                if let l = dd["lyric"] as? String, !l.isEmpty { return l }
                if let l = dd["lrc"] as? String, !l.isEmpty { return l }
            }
        }
        return nil
    }

    /// 洛雪返回可能包了一层 `{ action, data }`，这里剥掉外层只取 data。
    private func unwrapActionData(_ raw: Any?) -> Any? {
        guard let dict = raw as? [String: Any],
              let action = dict["action"] as? String, !action.isEmpty,
              let data = dict["data"] else { return raw }
        return data
    }

    // MARK: - Promise 等待（主线程 RunLoop 泵动）

    private func awaitPromise(_ promise: JSValue?) -> Any? {
        guard let promise = promise, promise.forProperty("then")?.isObject == true else {
            return promise?.toObject()
        }
        var result: Any?
        let group = DispatchGroup()
        group.enter()
        let onFulfilled: @convention(block) (JSValue) -> Void = { value in
            result = value.toObject()
            group.leave()
        }
        let onRejected: @convention(block) (JSValue) -> Void = { [weak self] value in
            let reason = value.toString() ?? "unknown"
            NSLog("LuoxueMusic JS promise rejected: %@", reason)
            self?.lastActionError = "脚本 Promise 拒绝: \(reason)"
            group.leave()
        }
        promise.invokeMethod("then", withArguments: [onFulfilled, onRejected])
        while group.wait(timeout: .now() + 0.1) != .success {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return result
    }

    // MARK: - 网络

    /// 洛雪官方 `lx.request(url, options, callback)`：
    /// - 有 callback 时走回调 `(err, resp, body)`，`resp.body` 为响应字符串；
    /// - 无 callback 时返回 Promise<{statusCode, headers, body}>。
    private func bridgeRequest(ctx: JSContext, url: String, options: JSValue, callback: JSValue) -> JSValue? {
        let opts = (options.toDictionary() as? [String: Any]) ?? [:]
        let hasCallback = callback.isObject && callback.forProperty("call")?.isObject == true
        if hasCallback {
            asyncRequestRaw(url: url, options: opts) { [weak self] err, resp, body in
                self?.finishRequest(callback, err: err, resp: resp, body: body)
            }
            return nil
        }
        // 无回调：返回 Promise。
        guard let promiseCtor = ctx.objectForKeyedSubscript("Promise"), promiseCtor.isObject else { return nil }
        let executor: @convention(block) (JSValue, JSValue) -> Void = { [weak self] resolve, reject in
            self?.asyncRequestRaw(url: url, options: opts) { err, resp, body in
                if let err {
                    _ = reject.call(withArguments: [err])
                } else {
                    let result: [String: Any] = [
                        "statusCode": resp?["statusCode"] ?? 0,
                        "headers": resp?["headers"] ?? [:],
                        "body": body ?? ""
                    ]
                    _ = resolve.call(withArguments: [result])
                }
            }
        }
        guard let execValue = JSValue(object: executor, in: ctx), execValue.isObject else { return nil }
        return promiseCtor.construct(withArguments: [execValue])
    }

    /// 异步 HTTP，回调 `(err, resp, body)`，resp.body 为字符串。
    private func asyncRequestRaw(url: String, options: [String: Any],
                                 completion: @escaping (String?, [String: Any]?, String?) -> Void) {
        guard let u = URL(string: url) else {
            completion("invalid url: \(url)", nil, nil)
            return
        }
        var request = URLRequest(url: u)
        request.timeoutInterval = 15
        let method = (options["method"] as? String)?.uppercased() ?? "GET"
        var headers = options["headers"] as? [String: Any] ?? [:]
        var body: Data?

        switch options["body"] {
        case let str as String:
            body = str.data(using: .utf8)
        case let dict as [String: Any]:
            body = Self.encodeForm(dict).data(using: .utf8)
            if headers["Content-Type"] == nil && headers["content-type"] == nil {
                headers["Content-Type"] = "application/x-www-form-urlencoded"
            }
        default: break
        }
        if body == nil, let form = options["form"] as? [String: Any] {
            body = Self.encodeForm(form).data(using: .utf8)
            if headers["Content-Type"] == nil && headers["content-type"] == nil {
                headers["Content-Type"] = "application/x-www-form-urlencoded"
            }
        }
        if let b = body, method == "GET" { request.httpMethod = "POST" } else { request.httpMethod = method }
        for (k, v) in headers { request.setValue("\(v)", forHTTPHeaderField: k) }
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { data, resp, error in
            DispatchQueue.main.async {
                if let error {
                    completion(error.localizedDescription, nil, nil)
                    return
                }
                let http = resp as? HTTPURLResponse
                let respDict: [String: Any] = [
                    "statusCode": http?.statusCode ?? 0,
                    "headers": http?.allHeaderFields.mapValues { "\($0)" } ?? [:]
                ]
                let bodyStr = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                completion(nil, respDict, bodyStr)
            }
        }.resume()
    }

    private func finishRequest(_ callback: JSValue, err: String?, resp: [String: Any]?, body: String?) {
        let errValue: Any = err ?? NSNull()
        let respValue: Any = resp ?? NSNull()
        let bodyValue: Any = body ?? NSNull()
        callback.call(withArguments: [errValue, respValue, bodyValue])
    }

    private static func encodeForm(_ dict: [String: Any]) -> String {
        dict.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key
            let v = "\(value)".addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "\(value)"
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }

    /// 老式脚本的同步 request（阻塞等待，module.exports 格式兼容用）。
    private func syncRequest(url: String, options: [String: Any]) -> String? {
        guard let u = URL(string: url) else { return nil }
        var request = URLRequest(url: u)
        request.timeoutInterval = 15
        request.httpMethod = ((options["method"] as? String)?.uppercased()) ?? "GET"
        if let headers = options["headers"] as? [String: Any] {
            for (k, v) in headers { request.setValue("\(v)", forHTTPHeaderField: k) }
        }
        if let body = options["body"] as? String, let data = body.data(using: .utf8) {
            request.httpBody = data
        }
        var result: String?
        let semaphore = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data = data, let str = String(data: data, encoding: .utf8) {
                result = str
            }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 20)
        return result
    }

    // MARK: - 脚本头信息解析（@name/@description/@version/@author/@homepage）

    static func parseScriptInfo(_ script: String) -> [String: Any] {
        var info: [String: String] = [:]
        let tags: [(String, String)] = [("@name", "name"), ("@description", "description"),
                                        ("@version", "version"), ("@author", "author"),
                                        ("@homepage", "homepage")]
        for (tag, key) in tags {
            if let value = capture(in: script, pattern: "^\\s*[*/]*\\s*\(tag)\\s+(.+?)\\s*$") {
                info[key] = value
            }
        }
        return info
    }

    private static func capture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return nil }
        let ns = text as NSString
        guard let m = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges >= 2 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    // MARK: - 加解密（CommonCrypto / Security / Compression）

    private static func runCipher(encrypt: Bool, data: [Int], mode: String, key: [Int], iv: [Int]) -> [Int] {
        let m = mode.lowercased()
        let algorithm: CCAlgorithm
        let keySize: Int
        if m.contains("3des") || m.contains("des-ede3") {
            algorithm = CCAlgorithm(kCCAlgorithm3DES)
            keySize = key.count >= 24 ? 24 : 16
        } else if m.hasPrefix("des") {
            algorithm = CCAlgorithm(kCCAlgorithmDES)
            keySize = 8
        } else if m.contains("256") {
            algorithm = CCAlgorithm(kCCAlgorithmAES)
            keySize = 32
        } else if m.contains("192") {
            algorithm = CCAlgorithm(kCCAlgorithmAES)
            keySize = 24
        } else {
            algorithm = CCAlgorithm(kCCAlgorithmAES)
            keySize = 16
        }
        let isECB = m.contains("ecb") || (m.contains("ede") && !m.contains("cbc"))
        let options: CCOptions = isECB ? CCOptions(kCCOptionECBMode) : 0
        let blockSize = (algorithm == CCAlgorithm(kCCAlgorithmDES) || algorithm == CCAlgorithm(kCCAlgorithm3DES)) ? 8 : 16

        var keyBytes = [UInt8](key.prefix(32).map { UInt8($0) })
        guard keyBytes.count >= keySize else { return [] }
        keyBytes = Array(keyBytes.prefix(keySize))
        var ivBytes = [UInt8](iv.prefix(blockSize).map { UInt8($0) })
        guard isECB || ivBytes.count >= blockSize else { return [] }

        var dataBytes = [UInt8](data.map { UInt8($0) })
        guard !dataBytes.isEmpty else { return [] }
        var out = [UInt8](repeating: 0, count: dataBytes.count + blockSize)
        var moved = 0
        let status = dataBytes.withUnsafeBufferPointer { dp in
            keyBytes.withUnsafeBufferPointer { kp in
                ivBytes.withUnsafeBufferPointer { ip in
                    CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt),
                            algorithm, options,
                            kp.baseAddress, kp.count,
                            isECB ? nil : ip.baseAddress,
                            dp.baseAddress, dp.count,
                            &out, out.count, &moved)
                }
            }
        }
        guard status == kCCSuccess else { return [] }
        return Array(out.prefix(moved)).map { Int($0) }
    }

    /// RSA 加密（RSA_NO_PADDING，与洛雪桌面端一致）：把 buffer 左补齐到密钥块大小后加密。
    private static func rsaEncrypt(bytes: [Int], pemKey: String) -> [Int]? {
        var pem = pemKey
        for token in ["-----BEGIN PUBLIC KEY-----", "-----END PUBLIC KEY-----",
                      "-----BEGIN RSA PUBLIC KEY-----", "-----END RSA PUBLIC KEY-----", "\n", "\r"] {
            pem = pem.replacingOccurrences(of: token, with: "")
        }
        pem = pem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let derData = Data(base64Encoded: pem) else { return nil }
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic
        ]
        var error: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(derData as CFData, attrs as CFDictionary, &error) else {
            return nil
        }
        let blockSize = SecKeyGetBlockSize(secKey)
        var buf = bytes.map { UInt8($0 & 0xFF) }
        guard buf.count <= blockSize else { return nil }
        if buf.count < blockSize {
            buf = Array(repeating: 0, count: blockSize - buf.count) + buf
        }
        var out = [UInt8](repeating: 0, count: blockSize)
        var outLen = blockSize
        let status = buf.withUnsafeBytes { bufPtr in
            out.withUnsafeMutableBytes { outPtr in
                SecKeyEncrypt(secKey, SecPadding(rawValue: 0),
                              bufPtr.baseAddress!, buf.count,
                              outPtr.baseAddress!, &outLen)
            }
        }
        guard status == errSecSuccess else { return nil }
        return Array(out.prefix(outLen)).map { Int($0) }
    }

    /// zlib 压缩/解压（COMPRESSION_ZLIB）。
    private static func zlibOp(bytes: [Int], compress: Bool) -> [Int] {
        let input = bytes.map { UInt8($0 & 0xFF) }
        guard !input.isEmpty else { return [] }
        let capacity = compress ? input.count * 2 + 1024 : input.count * 4 + 1024
        var out = [UInt8](repeating: 0, count: max(capacity, 64))
        let outCount = out.count
        let written = input.withUnsafeBytes { inPtr in
            out.withUnsafeMutableBytes { outPtr in
                if compress {
                    return compression_encode_buffer(outPtr.baseAddress!.bindMemory(to: UInt8.self, capacity: outCount), outCount,
                                                    inPtr.baseAddress!.bindMemory(to: UInt8.self, capacity: input.count), input.count,
                                                    nil, COMPRESSION_ZLIB)
                } else {
                    return compression_decode_buffer(outPtr.baseAddress!.bindMemory(to: UInt8.self, capacity: outCount), outCount,
                                                    inPtr.baseAddress!.bindMemory(to: UInt8.self, capacity: input.count), input.count,
                                                    nil, COMPRESSION_ZLIB)
                }
            }
        }
        guard written > 0 else { return [] }
        return Array(out.prefix(written)).map { Int($0) }
    }

    /// JS 值 → 字节数组（Buffer shim / 字符串 / 数组）。
    static func bytesOf(_ value: JSValue) -> [Int] {
        if value.isString {
            return Array(value.toString()!.utf8).map { Int($0) }
        }
        if value.isObject {
            if let data = value.objectForKeyedSubscript("data"), data.isArray,
               let arr = data.toArray() as? [NSNumber] {
                return arr.map { $0.intValue }
            }
            if let arr = value.toArray() as? [NSNumber] {
                return arr.map { $0.intValue }
            }
        }
        return []
    }

    // MARK: - 预置 JS（console / 定时器 / Buffer / lx 工厂）

    private static let preludeJS = """
    (function(){
      if (typeof console === 'undefined') {
        globalThis.console = {};
      }
      console.log = console.info = function(){ __lx_log(Array.prototype.join.call(arguments, ' ')); };
      console.warn = console.error = function(){ __lx_log('[warn] ' + Array.prototype.join.call(arguments, ' ')); };

      globalThis.setTimeout = function(fn, ms){ return __lx_timer(fn, Number(ms) || 0, false); };
      globalThis.clearTimeout = function(id){ __lx_timer_clear(id); };
      globalThis.setInterval = function(fn, ms){ return __lx_timer(fn, Number(ms) || 1, true); };
      globalThis.clearInterval = globalThis.clearTimeout;

      var B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
      function u8ToB64(bytes){ var r = '', i, len = bytes.length;
        for (i = 0; i + 2 < len; i += 3) { var n = (bytes[i] << 16) | (bytes[i+1] << 8) | bytes[i+2];
          r += B64[n >> 18 & 63] + B64[n >> 12 & 63] + B64[n >> 6 & 63] + B64[n & 63]; }
        if (i === len - 1) { var n1 = bytes[i] << 16; r += B64[n1 >> 18 & 63] + B64[n1 >> 12 & 63] + '=='; }
        else if (i === len - 2) { var n2 = (bytes[i] << 16) | (bytes[i+1] << 8); r += B64[n2 >> 18 & 63] + B64[n2 >> 12 & 63] + B64[n2 >> 6 & 63] + '='; }
        return r; }
      function b64ToU8(s){ s = String(s).replace(/[^A-Za-z0-9+\\/]/g, ''); var out = [], i;
        for (i = 0; i + 3 < s.length; i += 4) { var n = (B64.indexOf(s[i]) << 18) | (B64.indexOf(s[i+1]) << 12) | (B64.indexOf(s[i+2]) << 6) | B64.indexOf(s[i+3]);
          out.push(n >> 16 & 255, n >> 8 & 255, n & 255); }
        var rem = s.length - i;
        if (rem === 2) { var m2 = (B64.indexOf(s[i]) << 18) | (B64.indexOf(s[i+1]) << 12); out.push(m2 >> 16 & 255); }
        else if (rem === 3) { var m3 = (B64.indexOf(s[i]) << 18) | (B64.indexOf(s[i+1]) << 12) | (B64.indexOf(s[i+2]) << 6); out.push(m3 >> 16 & 255, m3 >> 8 & 255); }
        return out; }
      function hexToU8(s){ s = String(s); var out = [];
        for (var i = 0; i + 1 < s.length; i += 2) { var v = parseInt(s.substr(i, 2), 16); out.push(isNaN(v) ? 0 : v); }
        return out; }
      function u8ToHex(bytes){ var r = '';
        for (var i = 0; i < bytes.length; i++) r += ('0' + (bytes[i] & 255).toString(16)).slice(-2);
        return r; }
      function strToU8(s){ s = String(s); var out = [];
        for (var i = 0; i < s.length; i++) { var c = s.charCodeAt(i);
          if (c < 0x80) out.push(c);
          else if (c < 0x800) out.push(0xC0 | c >> 6, 0x80 | c & 63);
          else if (c >= 0xD800 && c <= 0xDBFF && i + 1 < s.length) { var c2 = s.charCodeAt(++i);
            var cp = 0x10000 + ((c - 0xD800) << 10) + (c2 - 0xDC00);
            out.push(0xF0 | cp >> 18, 0x80 | (cp >> 12) & 63, 0x80 | (cp >> 6) & 63, 0x80 | cp & 63); }
          else out.push(0xE0 | c >> 12, 0x80 | (c >> 6) & 63, 0x80 | c & 63); }
        return out; }
      function u8ToStr(bytes){ var s = '';
        for (var i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i] & 255);
        try { return decodeURIComponent(escape(s)); } catch (e) { return s; } }
      function mkBuf(bytes){ bytes = bytes.slice(); return {
        __lxbuf: true, length: bytes.length, data: bytes,
        toString: function(enc){ enc = (enc || 'utf-8').toLowerCase();
          if (enc === 'base64') return u8ToB64(this.data);
          if (enc === 'hex') return u8ToHex(this.data);
          if (enc === 'latin1' || enc === 'binary' || enc === 'ascii')
            return Array.prototype.map.call(this.data, function(b){ return String.fromCharCode(b & 255); }).join('');
          return u8ToStr(this.data); },
        slice: function(a, b){ return mkBuf(this.data.slice(a || 0, b)); },
        toJSON: function(){ return u8ToStr(this.data); } }; }
      function bytesOf(x){ if (x && x.__lxbuf) return x.data;
        if (typeof x === 'string') return strToU8(x);
        if (Array.isArray(x)) return x.map(function(v){ return v & 255; });
        if (x && typeof x === 'object' && typeof x.length === 'number') { var o = [];
          for (var i = 0; i < x.length; i++) o.push(x[i] & 255); return o; }
        return []; }
      function bufToString(buf, enc){ var b = (buf && buf.__lxbuf) ? buf.data : (Array.isArray(buf) ? buf : []);
        enc = (enc || 'utf-8').toLowerCase();
        if (enc === 'base64') return u8ToB64(b);
        if (enc === 'hex') return u8ToHex(b);
        return u8ToStr(b); }

      var utils = {
        buffer: {
          from: function(input, enc){
            if (input && input.__lxbuf) return mkBuf(input.data);
            enc = (enc || 'utf-8').toLowerCase();
            if (typeof input === 'string') {
              if (enc === 'base64') return mkBuf(b64ToU8(input));
              if (enc === 'hex') return mkBuf(hexToU8(input));
              return mkBuf(strToU8(input));
            }
            if (input && typeof input.length === 'number') { var a = [];
              for (var i = 0; i < input.length; i++) a.push(input[i] & 255); return mkBuf(a); }
            return mkBuf([]);
          },
          bufToString: bufToString,
          isBuffer: function(x){ return !!(x && x.__lxbuf); }
        },
        crypto: {
          md5: function(data){ return __lx_md5(bytesOf(data)); },
          sha1: function(data){ return __lx_sha1(bytesOf(data)); },
          randomBytes: function(n){ return mkBuf(__lx_random(n)); },
          aesEncrypt: function(data, mode, key, iv){ return mkBuf(__lx_cipher(true, bytesOf(data), String(mode), bytesOf(key), iv == null ? [] : bytesOf(iv))); },
          aesDecrypt: function(data, mode, key, iv){ return mkBuf(__lx_cipher(false, bytesOf(data), String(mode), bytesOf(key), iv == null ? [] : bytesOf(iv))); },
          desEncrypt: function(data, mode, key, iv){ return mkBuf(__lx_cipher(true, bytesOf(data), String(mode), bytesOf(key), iv == null ? [] : bytesOf(iv))); },
          desDecrypt: function(data, mode, key, iv){ return mkBuf(__lx_cipher(false, bytesOf(data), String(mode), bytesOf(key), iv == null ? [] : bytesOf(iv))); },
          rsaEncrypt: function(data, key){ return mkBuf(__lx_rsa(bytesOf(data), String(key))); }
        },
        zlib: {
          inflate: function(buffer){ return Promise.resolve(mkBuf(__lx_inflate(bytesOf(buffer)))); },
          deflate: function(buffer){ return Promise.resolve(mkBuf(__lx_deflate(bytesOf(buffer)))); }
        }
      };
      globalThis.__lx_utils = utils;

      globalThis.__lx_makeLX = function(info, hooks){
        var lx = {
          EVENT_NAMES: { request: 'request', inited: 'inited', updateAlert: 'updateAlert' },
          env: 'mobile',
          version: '2.0.0',
          currentScriptInfo: info,
          on: function(name, fn){ if (name === 'request') hooks.onHandler(fn); },
          send: function(name, data){
            if (name === 'request') return;
            hooks.onSend(String(name), data || {});
            return Promise.resolve();
          },
          utils: utils,
          request: hooks.request
        };
        return lx;
      };
    })();
    """
}

private extension Song {
    /// 传给音源脚本的歌曲信息（洛雪官方字段 + 常见别名字段都覆盖）。
    func toSourceInfo() -> [String: Any] {
        return [
            "songmid": songId, "songid": songId, "id": songId, "hash": songId,
            "songname": title, "name": title, "title": title,
            "singer": artist, "artist": artist, "artists": artist,
            "albumname": album, "albumName": album, "album": album,
            "source": source, "img": picUrl, "pic": picUrl, "interval": duration
        ]
    }
}
