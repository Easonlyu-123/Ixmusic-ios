import Foundation
import JavaScriptCore
import CommonCrypto

/// 通过 JavaScriptCore 执行洛雪格式音源脚本，内核对齐 lx-music 官方 user-api：
///
/// 1. 官方格式（lx-music-desktop / lx-music-mobile 自定义音源）：
///    脚本通过 `globalThis.lx` 使用 `EVENT_NAMES`、`on`、`send`、`utils`（buffer/crypto）、
///    `request`（异步 HTTP 桥）与 `currentScriptInfo`；以
///    `on(EVENT_NAMES.request, handler)` 注册处理器，`send(EVENT_NAMES.inited, {...})` 完成初始化。
///    handler 收到 `{ source, action, info }`，action ∈ musicSearch / musicUrl / lyric / pic，
///    可直接返回值、返回 Promise，或调用第二参数 callback(err, data) 异步响应。
/// 2. 兼容格式：`module.exports = { musicSearch, getMusicUrl, getLyric }` 老式导出同样支持。
///
/// 所有 JS 调用都在主线程执行；网络请求用 URLSession 异步发起，回调派回主线程，
/// 由主线程 RunLoop 泵动处理（不阻塞 UI，也不会死锁）。
final class SourceRuntime {

    private static let eventInited = "inited"
    private static let eventRequest = "request"
    private static let jsEnv = "mobile"
    private static let jsVersion = "1.4.6"

    /// 单个脚本编译后的缓存：老式导出对象 + 洛雪 user-api 桥。
    private struct ScriptEntry {
        var exports: JSValue?
        var requestHandler: JSValue?
        var inited: [String: Any]?
    }

    /// 桥接箱：脚本 eval 时 native 闭包往里写 handler / inited。
    private final class BridgeBox {
        var requestHandler: JSValue?
        var inited: [String: Any]?
    }

    private var _context: JSContext?
    private var entries: [String: ScriptEntry] = [:]

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

    func getLyric(source: MusicSource, song: Song) async -> String? {
        await withCheckedContinuation { cont in
            self.runOnMainAndWait {
                let lyric = self.lyricOnMain(source: source, song: song)
                cont.resume(returning: lyric)
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

    /// 预置 JS 环境：console、定时器、Buffer shim、lx.utils（buffer/crypto）、lx 工厂。
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

        let cipherBlock: @convention(block) (Bool, JSValue, String, JSValue, JSValue) -> Any = { encrypt, data, mode, key, iv in
            Self.runCipher(encrypt: encrypt,
                           data: Self.bytesOf(data),
                           mode: mode,
                           key: Self.bytesOf(key),
                           iv: iv.isUndefined || iv.isNull ? [] : Self.bytesOf(iv))
        }
        ctx.setObject(cipherBlock, forKeyedSubscript: "__lx_cipher" as NSString)

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
        if let cached = entries[source.script] { return cached }
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
        let request: @convention(block) (String, JSValue, JSValue) -> Void = { [weak self] url, options, callback in
            self?.asyncRequest(url: url, options: options, callback: callback)
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
                                inited: box.inited)
        guard entry.exports != nil || entry.requestHandler != nil else { return nil }
        entries[source.script] = entry
        return entry
    }

    // MARK: - 调用（老式导出 → 方法；官方格式 → request handler）

    private func searchOnMain(source: MusicSource, query: String, page: Int) -> [Song]? {
        let ctx = context()
        guard let entry = prepare(ctx, source: source) else { return nil }
        var raw: Any?
        if let fn = entry.exports?.objectForKeyedSubscript("musicSearch"), isCallable(fn) {
            raw = resolve(fn.call(withArguments: [query, page, 30]))
        } else if entry.requestHandler != nil {
            raw = invokeRequest(entry, ctx, platform: source.platform, action: "musicSearch",
                                info: ["searchWord": query, "page": page, "limit": 30])
        }
        guard raw != nil else { return nil }
        return parseSongs(raw, platform: source.platform)
    }

    private func urlOnMain(source: MusicSource, song: Song) -> String? {
        let ctx = context()
        guard let entry = prepare(ctx, source: source) else { return nil }
        var raw: Any?
        if let fn = entry.exports?.objectForKeyedSubscript("getMusicUrl"), isCallable(fn) {
            raw = resolve(fn.call(withArguments: [song.toSourceInfo()]))
        } else if entry.requestHandler != nil {
            raw = invokeRequest(entry, ctx, platform: source.platform, action: "musicUrl",
                                info: ["musicInfo": song.toSourceInfo(), "type": "128k"])
        }
        if let str = raw as? String, !str.isEmpty { return str }
        if let dict = raw as? [String: Any], let url = dict["url"] as? String, !url.isEmpty { return url }
        return nil
    }

    private func lyricOnMain(source: MusicSource, song: Song) -> String? {
        let ctx = context()
        guard let entry = prepare(ctx, source: source) else { return nil }
        var raw: Any?
        if let fn = entry.exports?.objectForKeyedSubscript("getLyric"), isCallable(fn) {
            raw = resolve(fn.call(withArguments: [song.toSourceInfo()]))
        } else if entry.requestHandler != nil {
            raw = invokeRequest(entry, ctx, platform: source.platform, action: "lyric",
                                info: ["musicInfo": song.toSourceInfo()])
        }
        if let str = raw as? String, !str.isEmpty { return str }
        if let dict = raw as? [String: Any] {
            if let lyric = dict["lyric"] as? String, !lyric.isEmpty { return lyric }
            if let std = dict["standard"] as? String, !std.isEmpty { return std }
        }
        return nil
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

    /// 调用洛雪官方 request 处理器。支持三种响应方式：
    /// 返回 Promise / 直接返回值 / 调用第二参数 callback(err, data)。
    private func invokeRequest(_ entry: ScriptEntry, _ ctx: JSContext,
                               platform: String, action: String, info: [String: Any]) -> Any? {
        guard let handler = entry.requestHandler else { return nil }
        let box = CallbackBox()
        let callback: @convention(block) (JSValue, JSValue) -> Void = { err, data in
            guard !box.done else { return }
            box.done = true
            if err.isUndefined || err.isNull {
                box.result = data.toObject()
            }
        }
        let params: [String: Any] = ["source": platform, "action": action, "info": info]
        let result = handler.call(withArguments: [params, callback])
        if let result, result.forProperty("then")?.isObject == true {
            return awaitPromise(result)
        }
        if let result, !result.isUndefined && !result.isNull {
            return result.toObject()
        }
        // 异步响应：泵动主线程 RunLoop 等待 callback。
        var waited: TimeInterval = 0
        while !box.done && waited < 30 {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            waited += 0.05
        }
        return box.result
    }

    private final class CallbackBox {
        var done = false
        var result: Any?
    }

    // MARK: - 结果解析

    private func parseSongs(_ raw: Any?, platform: String) -> [Song]? {
        if let arr = raw as? [[String: Any]] {
            return arr.compactMap { song(from: $0, platform: platform) }
        }
        if let dict = raw as? [String: Any], let list = dict["list"] as? [[String: Any]] {
            return list.compactMap { song(from: $0, platform: platform) }
        }
        return nil
    }

    private func song(from dict: [String: Any], platform: String) -> Song? {
        let title = (dict["songname"] as? String) ?? (dict["name"] as? String) ?? (dict["title"] as? String) ?? ""
        let artist = Self.flattenArtist(dict["singer"] ?? dict["artist"])
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
        let onRejected: @convention(block) (JSValue) -> Void = { value in
            NSLog("LuoxueMusic JS promise rejected: \(value.toString() ?? "unknown")")
            group.leave()
        }
        promise.invokeMethod("then", withArguments: [onFulfilled, onRejected])
        while group.wait(timeout: .now() + 0.1) != .success {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return result
    }

    // MARK: - 网络

    /// 洛雪官方 lx.request(url, options, callback)：异步 HTTP，回调 (err, resp, body)。
    private func asyncRequest(url: String, options: JSValue, callback: JSValue) {
        let opts = (options.toDictionary() as? [String: Any]) ?? [:]
        guard let u = URL(string: url) else {
            finishRequest(callback, err: "invalid url: \(url)", resp: nil, body: nil)
            return
        }
        var request = URLRequest(url: u)
        request.timeoutInterval = 15
        var method = (opts["method"] as? String)?.uppercased() ?? "GET"
        var headers = opts["headers"] as? [String: Any] ?? [:]
        var body: Data?

        switch opts["body"] {
        case let str as String:
            body = str.data(using: .utf8)
        case let dict as [String: Any]:
            body = Self.encodeForm(dict).data(using: .utf8)
            if headers["Content-Type"] == nil && headers["content-type"] == nil {
                headers["Content-Type"] = "application/x-www-form-urlencoded"
            }
        default: break
        }
        if body == nil, let form = opts["form"] as? [String: Any] {
            body = Self.encodeForm(form).data(using: .utf8)
            if headers["Content-Type"] == nil && headers["content-type"] == nil {
                headers["Content-Type"] = "application/x-www-form-urlencoded"
            }
        }
        if let b = body, method == "GET" { method = "POST" }
        request.httpMethod = method
        for (k, v) in headers { request.setValue("\(v)", forHTTPHeaderField: k) }
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { data, resp, error in
            DispatchQueue.main.async {
                if let error {
                    self.finishRequest(callback, err: error.localizedDescription, resp: nil, body: nil)
                    return
                }
                let http = resp as? HTTPURLResponse
                let respDict: [String: Any] = [
                    "statusCode": http?.statusCode ?? 0,
                    "headers": http?.allHeaderFields.mapValues { "\($0)" } ?? [:]
                ]
                let bodyStr = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                self.finishRequest(callback, err: nil, resp: respDict, body: bodyStr)
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

    // MARK: - 加解密（CommonCrypto）

    private static func runCipher(encrypt: Bool, data: [Int], mode: String, key: [Int], iv: [Int]) -> Any {
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
        let isECB = m.contains("ecb") || m.contains("ede") && !m.contains("cbc")
        let options: CCOptions = isECB ? CCOptions(kCCOptionECBMode) : 0
        let blockSize = algorithm == CCAlgorithm(kCCAlgorithmDES) || algorithm == CCAlgorithm(kCCAlgorithm3DES) ? 8 : 16

        var keyBytes = [UInt8](key.prefix(32).map { UInt8($0) })
        if keyBytes.count < keySize { return [] }
        keyBytes = Array(keyBytes.prefix(keySize))
        var ivBytes = [UInt8](iv.prefix(blockSize).map { UInt8($0) })
        if ivBytes.count < blockSize && !isECB { return [] }

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

    /// JS 值 → 字节数组（Buffer shim / 字符串 / 数组）。
    static func bytesOf(_ value: JSValue) -> [Int] {
        if value.isString {
            return Array(value.toString()!.utf8).map { Int($0) }
        }
        if value.isObject {
            // Buffer shim：{ __lxbuf: true, data: [...] }
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
          rsaEncrypt: function(){ throw new Error('rsaEncrypt 暂不支持'); }
        },
        zlib: {}
      };
      globalThis.__lx_utils = utils;

      globalThis.__lx_makeLX = function(info, hooks){
        var lx = {
          EVENT_NAMES: { request: 'request', inited: 'inited', updateAlert: 'updateAlert' },
          env: 'mobile',
          version: '1.4.6',
          currentScriptInfo: info,
          on: function(name, fn){ if (name === 'request') hooks.onHandler(fn); },
          send: function(name, data){ hooks.onSend(String(name), data); },
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
            "singer": artist, "artist": artist,
            "albumname": album, "albumName": album, "album": album,
            "source": source, "img": picUrl, "pic": picUrl, "interval": duration
        ]
    }
}
