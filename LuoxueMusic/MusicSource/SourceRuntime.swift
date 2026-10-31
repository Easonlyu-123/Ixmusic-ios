import Foundation
import JavaScriptCore

/// 通过 JavaScriptCore 执行洛雪格式（lx-music-source）的 JS 音源脚本。
///
/// 音源格式保持不变：脚本以 `module.exports = { name, version, platform, author,
/// musicSearch, getMusicUrl, getLyric }` 导出。运行时向 JS 注入一个同步的
/// `request(url, options)` 全局函数，供音源脚本拉取各平台的公开接口。
///
/// 所有 JS 调用都派发到主线程执行：JavaScriptCore 要求同一 JSContext 在单一线程
/// 使用，且 Promise 的回调依赖该线程的 RunLoop；主线程天然满足条件。代价是网络请求
/// 会在主线程同步等待（MVP 限制），后续可改为真正的异步 request 桥接以消除卡顿。
final class SourceRuntime {

    private var _context: JSContext?
    // 每段脚本只编译/执行一次并缓存其导出的音源对象。
    // 关键：洛雪音源脚本普遍用 `const source = {...}; module.exports = source;`
    // 声明在全局作用域。若每次搜索都直接 eval 整段，第二次执行会因“标识符已声明”
    // 抛异常，导致真实音源在首次搜索后全部失效。故用 IIFE 把脚本包进独立函数作用域，
    // 既能隔离不同音源之间的顶层声明冲突，又能安全复用。
    private var exportsCache: [String: JSValue] = [:]

    // MARK: - 公开接口

    func search(source: MusicSource, query: String, page: Int = 1) async -> [Song]? {
        await withCheckedContinuation { cont in
            self.runOnMainAndWait {
                let songs = self.callListMethod(source: source, method: "musicSearch",
                                               args: [query, page, 30], platform: source.platform)
                cont.resume(returning: songs)
            }
        }
    }

    func getUrl(source: MusicSource, song: Song) async -> String? {
        await withCheckedContinuation { cont in
            self.runOnMainAndWait {
                let url = self.callContentMethod(source: source, method: "getMusicUrl", song: song, key: "url")
                cont.resume(returning: url)
            }
        }
    }

    func getLyric(source: MusicSource, song: Song) async -> String? {
        await withCheckedContinuation { cont in
            self.runOnMainAndWait {
                let lyric = self.callContentMethod(source: source, method: "getLyric", song: song, key: "lyric")
                cont.resume(returning: lyric)
            }
        }
    }

    // MARK: - 线程调度（确保 JS 始终在主线程执行）

    private func runOnMainAndWait(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.sync(execute: block)
        }
    }

    // MARK: - JS 上下文（必须在主线程调用）

    private func context() -> JSContext {
        if let existing = _context { return existing }
        let ctx = JSContext()!
        ctx.exceptionHandler = { _, exception in
            if let e = exception {
                NSLog("LuoxueMusic JS exception: \(e.toString() ?? "unknown")")
            }
        }
        // 注入同步网络请求：洛雪音源脚本内部通过全局 request 拉取平台接口。
        let requestBlock: @convention(block) (String, JSValue) -> String? = { [weak self] url, optionsValue in
            let options = (optionsValue.toDictionary() as? [String: Any]) ?? [:]
            return self?.syncRequest(url: url, options: options)
        }
        ctx.setObject(requestBlock, forKeyedSubscript: "request" as NSString)
        _context = ctx
        return ctx
    }

    // MARK: - 同步调用

    private func prepare(_ ctx: JSContext, source: MusicSource) -> JSValue? {
        if let cached = exportsCache[source.script] {
            return cached
        }
        // 用 IIFE 把脚本包进独立函数作用域执行，避免顶层 `const source` 在多次/多音源间冲突。
        let wrapper = """
        (function() {
          var module = { exports: {} };
          var exports = module.exports;
          \(source.script)
          return module.exports;
        })()
        """
        guard let exports = ctx.evaluateScript(wrapper),
              !exports.isUndefined, !exports.isNull else {
            return nil
        }
        exportsCache[source.script] = exports
        return exports
    }

    private func callListMethod(source: MusicSource, method: String, args: [Any], platform: String) -> [Song]? {
        let ctx = context()
        guard let exports = prepare(ctx, source: source) else { return nil }
        guard let fn = exports.objectForKeyedSubscript(method), !fn.isUndefined, !fn.isNull else { return nil }
        let result = fn.call(withArguments: args)
        guard let raw = awaitPromise(result) else { return nil }
        return parseSongs(raw, platform: platform)
    }

    private func callContentMethod(source: MusicSource, method: String, song: Song, key: String) -> String? {
        let ctx = context()
        guard let exports = prepare(ctx, source: source) else { return nil }
        guard let fn = exports.objectForKeyedSubscript(method), !fn.isUndefined, !fn.isNull else { return nil }
        let result = fn.call(withArguments: [song.toSourceInfo()])
        guard let raw = awaitPromise(result) else { return nil }
        if let dict = raw as? [String: Any] {
            return dict[key] as? String
        }
        return raw as? String
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
        let artist = (dict["singer"] as? String) ?? (dict["artist"] as? String) ?? ""
        let album = (dict["albumname"] as? String) ?? (dict["album"] as? String) ?? ""
        let songId = String(describing: dict["songmid"] ?? dict["id"] ?? dict["songid"] ?? UUID().uuidString)
        let duration = (dict["interval"] as? Int) ?? (dict["duration"] as? Int) ?? 0
        let pic = (dict["pic"] as? String) ?? (dict["picUrl"] as? String) ?? (dict["image"] as? String) ?? ""
        let lrc = (dict["lrcUrl"] as? String) ?? (dict["lyricUrl"] as? String) ?? ""
        guard !title.isEmpty else { return nil }
        return Song(source: platform, songId: songId, title: title, artist: artist,
                    album: album, duration: duration, picUrl: pic, lrcUrl: lrc)
    }

    // MARK: - Promise 等待（主线程 RunLoop 驱动，避免死锁）

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
        let onRejected: @convention(block) (JSValue) -> Void = { _ in
            group.leave()
        }
        promise.invokeMethod("then", withArguments: [onFulfilled, onRejected])
        // 在主线程 RunLoop 上轮询，直到 Promise 回调触发（microtask 由 RunLoop 处理）。
        while group.wait(timeout: .now() + 0.1) != .success {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return result
    }

    // MARK: - 网络（MVP：主线程同步请求；后续改为异步 request 桥接）

    private func syncRequest(url: String, options: [String: Any]) -> String? {
        guard let u = URL(string: url) else { return nil }
        var request = URLRequest(url: u)
        request.timeoutInterval = 15
        if let method = options["method"] as? String, !method.isEmpty {
            request.httpMethod = method.uppercased()
        } else {
            request.httpMethod = "GET"
        }
        if let headers = options["headers"] as? [String: String] {
            for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
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
}

private extension Song {
    /// 传给音源脚本的歌曲信息（洛雪常用字段名尽量覆盖）。
    func toSourceInfo() -> [String: Any] {
        return [
            "songmid": songId, "songid": songId, "id": songId,
            "songname": title, "name": title, "title": title,
            "singer": artist, "artist": artist,
            "albumname": album, "album": album,
            "source": source, "pic": picUrl, "interval": duration
        ]
    }
}
