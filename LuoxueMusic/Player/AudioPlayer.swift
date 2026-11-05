import AVFoundation
import SwiftUI

/// 基于 AVPlayer 的播放器封装，要求在主线程使用（@MainActor）。
///
/// 关键设计：各平台 CDN 直链（网易云 / 酷我 / QQ）常要求带 `Referer` 等请求头，
/// 且 `AVAssetResourceLoader` 在侧载 / 未签名环境下极不稳定（多次迭代均出现“能打开但放不出 / 报错”）。
/// 因此改为「先把音频用带头的 URLSession 下载到本地缓存，再用 AVPlayer 播放本地文件」，
/// 既兼容各 CDN 的头部要求，又完全绕开资源加载器拦截的坑，播放最稳定；同一首歌二次播放直接读缓存。
@MainActor
@Observable
final class AudioPlayer {
    var isPlaying = false
    var currentTime: Double = 0
    var duration: Double = 0
    var currentURL: String?
    /// 是否正在下载音频（用于 UI 显示加载态）。
    var isLoading = false
    /// 播放失败原因（如下载失败 / 本地文件损坏），用于透传给 UI 提示。
    var error: String?

    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var timeObserverToken: Any?
    private var statusObserver: NSKeyValueObservation?
    /// 下载器（强引用；随 AudioPlayer 生命周期存活）。
    private let downloader = AudioFileDownloader()
    /// 当前加载任务，切歌时取消上一次。
    private var loadTask: Task<Void, Never>?

    init() {
        configureAudioSession()
    }

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.allowAirPlay, .allowBluetooth])
            try session.setActive(true)
        } catch {
            NSLog("LuoxueMusic audio session error: \(error)")
        }
    }

    /// 播放音频直链；headers 为各平台 CDN 所需的请求头（Referer 等）。
    ///
    /// 流程：下载到本地缓存 → AVPlayer 播放本地文件。下载中若切歌，上一次任务会被取消。
    func play(url: String, headers: [String: String] = [:]) {
        guard let u = URL(string: url) else {
            error = "无效的音频地址"
            return
        }
        error = nil
        isLoading = true
        loadTask?.cancel()
        let downloader = self.downloader
        loadTask = Task { [weak self] in
            do {
                let localURL = try await Self.cachedOrDownload(u, headers: headers, downloader: downloader)
                try Task.checkCancellation()
                guard let self else { return }
                await MainActor.run {
                    self.isLoading = false
                    let item = AVPlayerItem(url: localURL)
                    self.playerItem = item
                    self.player = AVPlayer(playerItem: item)
                    self.addTimeObserver(for: item)
                    self.observeStatus(item)
                    self.player?.play()
                    self.isPlaying = true
                    self.currentURL = url
                }
            } catch is CancellationError {
                await MainActor.run { self?.isLoading = false }
            } catch {
                await MainActor.run {
                    self?.isLoading = false
                    self?.error = "音频加载失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func togglePlayPause() {
        guard let player = player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    func stop() {
        player?.pause()
        cleanupItem()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        isLoading = false
    }

    func seek(to seconds: Double) {
        let s = max(0, seconds.isFinite ? seconds : 0)
        player?.seek(to: CMTime(seconds: s, preferredTimescale: 600))
        currentTime = s
    }

    // MARK: - 内部

    private func cleanupItem() {
        removeTimeObserver()
        statusObserver?.invalidate()
        statusObserver = nil
        playerItem = nil
    }

    private func addTimeObserver(for item: AVPlayerItem) {
        timeObserverToken = player?.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            self.currentTime = time.seconds
            let dur = item.duration
            if dur.isValid, dur.seconds > 0 {
                self.duration = dur.seconds
            }
        }
    }

    private func removeTimeObserver() {
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
            timeObserverToken = nil
        }
    }

    /// 监听播放条目状态：失败时把原因写入 `error` 以便 UI 提示。
    private func observeStatus(_ item: AVPlayerItem) {
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
            guard let self else { return }
            if observed.status == .failed {
                let reason = (observed.error as NSError?)?.localizedDescription
                    ?? "未知错误（可能是音频文件已失效或本地播放异常）"
                Task { @MainActor in self.error = reason }
            }
        }
    }

    // MARK: - 本地缓存

    /// 优先返回已缓存的本地音频；否则下载后落盘再返回。
    private static func cachedOrDownload(_ url: URL, headers: [String: String],
                                         downloader: AudioFileDownloader) async throws -> URL {
        let cached = cacheFileURL(for: url)
        if FileManager.default.fileExists(atPath: cached.path),
           let sz = try? FileManager.default.attributesOfItem(atPath: cached.path)[.size] as? UInt64,
           sz > 1024 {
            return cached
        }
        let tmp = try await downloader.fetch(url, headers: headers)
        try? FileManager.default.removeItem(at: cached)
        try FileManager.default.moveItem(at: tmp, to: cached)
        return cached
    }

    private static func cacheFileURL(for url: URL) -> URL {
        let base = (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                    ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("luoxue_audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let ext = url.pathExtension.isEmpty ? "mp3" : url.pathExtension
        return base.appendingPathComponent(stableName(url.absoluteString) + ".\(ext)")
    }

    /// 由字符串稳定派生文件名（FNV-1a 64 位），跨启动一致。内部可见以便单元测试。
    nonisolated static func stableName(_ key: String) -> String {
        let data = Data(key.utf8)
        var hash: UInt64 = 0xcbf29ce484222325
        for b in data {
            hash ^= UInt64(b)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}

/// 带自定义请求头（含 302 重定向时保持头部）的音频下载器，把远程直链落到本地临时文件。
///
/// 之所以单独成类：URLSession 的下载委托需要 NSObject 子类；重定向时网易云 / 酷我 / QQ 的 CDN
/// 仍要求带 Referer，需在 `willPerformHTTPRedirection` 里把注入的头部重新写回新请求。
private final class AudioFileDownloader: NSObject, URLSessionDownloadDelegate {
    private var session: URLSession!
    private var headers: [String: String] = [:]
    /// 当前在飞的下载 id（用于忽略上一次已取消的回调）。
    private var activeID: UUID?
    /// 每个下载 id 对应一个 continuation。
    private var pending: [UUID: CheckedContinuation<URL, Error>] = [:]

    override init() {
        super.init()
        session = makeSession()
    }

    private func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpMaximumConnectionsPerHost = 2
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 120
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    /// 下载音频到本地临时文件，返回本地文件 URL。重复调用会取消上一次仍在进行的下载。
    func fetch(_ url: URL, headers: [String: String]) async throws -> URL {
        // 取消上一次未完成的下载：先把它的 continuation 以取消错误结束，再作废旧 session。
        if let prev = activeID, let cont = pending.removeValue(forKey: prev) {
            cont.resume(throwing: CancellationError())
        }
        session.invalidateAndCancel()
        session = makeSession()
        self.headers = headers

        let id = UUID()
        activeID = id
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            var req = URLRequest(url: url, timeoutInterval: 60)
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            session.downloadTask(with: req).resume()
        }
    }

    private func finish(_ id: UUID, _ result: Result<URL, Error>) {
        guard let cont = pending.removeValue(forKey: id) else { return }
        cont.resume(with: result)
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = activeID else { return }
        let ext = (downloadTask.response?.url?.pathExtension).flatMap { $0.isEmpty ? nil : $0 } ?? "mp3"
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("lx_\(UUID().uuidString).\(ext)")
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            finish(id, .success(dest))
        } catch {
            finish(id, .failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = activeID, let error else { return }
        finish(id, .failure(error))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        var r = request
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        completionHandler(r)
    }
}
