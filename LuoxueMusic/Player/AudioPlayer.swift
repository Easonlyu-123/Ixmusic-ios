import AVFoundation
import SwiftUI
import Observation

/// 基于 AVPlayer 的播放器封装，要求在主线程使用（@MainActor）。
///
/// 播放机制（iOS 侧对齐洛雪「拿到可播直链交给系统播放器」的最稳等价实现）：
/// - 取链阶段由音源/内置平台拿到音频直链；
/// - **带请求头把直链下载到本地**（302 重定向、Referer/UA 都由可控的 URLSession 处理）——
///   自定义音源返回的 CDN 直链常需要 Referer，必须带；
/// - 再播**本地文件**（file URL 一定可播），彻底绕开 http CDN 直链在侧载真机上的流式不稳定；
/// - HTML/JSON/空数据直接判定为「无可播放音源」，给出可诊断的错误文本。
@MainActor
@Observable
final class AudioPlayer {
    var isPlaying = false
    var currentTime: Double = 0
    var duration: Double = 0
    var currentURL: String?
    /// 是否正在取链/加载音频（点歌瞬间即置 true，UI 立即有反馈）。
    var isLoading = false
    /// 播放失败原因，用于透传给 UI 提示。
    var error: String?
    /// 播放失败回调（AppStore 用来弹提示），由 MainActor 上的 fail 同步调用。
    @ObservationIgnored var onFailure: ((String) -> Void)?

    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var timeObserverToken: Any?
    private var statusObserver: NSKeyValueObservation?
    /// 播放序号：忽略被新请求取代的旧异步结果。
    private var playGeneration = 0

    init() {
        configureAudioSession()
    }

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.allowAirPlay, .allowBluetoothHFP])
            try session.setActive(true)
        } catch {
            NSLog("LuoxueMusic audio session error: \(error)")
        }
    }

    /// 仅把 UI 置为「加载中」（点歌瞬间调用，取链尚未开始时就有反馈）。
    func beginLoading() {
        error = nil
        isLoading = true
        isPlaying = false
        playGeneration += 1
    }

    /// 播放音频直链；headers 为该 CDN 所需的请求头（Referer/UA 等），下载时带上。
    func play(url: String, headers: [String: String] = [:]) {
        guard let u = URL(string: url), (u.scheme == "http" || u.scheme == "https") else {
            fail("无效的音频地址")
            return
        }
        error = nil
        isLoading = true
        isPlaying = false
        playGeneration += 1
        let gen = playGeneration
        Task { await self.downloadAndPlay(url: u, headers: headers, generation: gen) }
    }

    private func downloadAndPlay(url: URL, headers: [String: String], generation: Int) async {
        do {
            let local = try await fetchToLocal(url, headers: headers)
            guard generation == playGeneration else { return } // 被新请求取代
            startLocalPlayback(local)
        } catch {
            guard generation == playGeneration else { return }
            fail(error.localizedDescription)
        }
    }

    /// 带请求头下载音频到临时文件（URLSession 自动跟随 302 到最终 CDN）。
    /// 拒绝把 404 页 / 版权提示 / JSON 当音频，并给出可诊断的错误文本。
    private func fetchToLocal(_ url: URL, headers: [String: String]) async throws -> URL {
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        for (k, v) in headers where k.lowercased() != "user-agent" {
            req.setValue(v, forHTTPHeaderField: k)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse {
            let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            if !(200...299).contains(http.statusCode) {
                throw NSError(domain: "LuoxueMusic", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "服务器返回 HTTP \(http.statusCode)"])
            }
            if type.contains("text/html") || type.contains("application/json") || type.contains("text/plain") {
                throw NSError(domain: "LuoxueMusic", code: -2,
                              userInfo: [NSLocalizedDescriptionKey: "该歌曲暂无可播放音源（VIP/版权歌曲，或音源未返回直链）"])
            }
        }
        guard data.count > 1024 else {
            throw NSError(domain: "LuoxueMusic", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "音频数据为空或过小（\(data.count) 字节）"])
        }
        let ext = url.pathExtension.isEmpty ? "mp3" : url.pathExtension
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lx_\(UUID().uuidString).\(ext)")
        try data.write(to: tmp)
        return tmp
    }

    /// 播放本地文件（file URL，最可靠），本地解码失败才报错。
    private func startLocalPlayback(_ local: URL) {
        let item = AVPlayerItem(url: local)
        replaceCurrentItem(with: item)
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
            guard let self else { return }
            if observed.status == .failed {
                let r = (observed.error as NSError?)?.localizedDescription ?? "本地音频无法解码"
                Task { @MainActor in self.fail("本地文件播放失败：\(r)") }
            }
        }
        player?.play()
        isPlaying = true
        isLoading = false
        error = nil
        currentURL = local.absoluteString
    }

    func togglePlayPause() {
        guard let player else { return }
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

    private func fail(_ message: String) {
        error = message
        isLoading = false
        isPlaying = false
        onFailure?(message)
    }

    private func replaceCurrentItem(with item: AVPlayerItem) {
        removeTimeObserver()
        statusObserver?.invalidate()
        statusObserver = nil
        playerItem = item
        if player == nil {
            player = AVPlayer(playerItem: item)
        } else {
            player?.replaceCurrentItem(with: item)
        }
        addTimeObserver(for: item)
    }

    private func cleanupItem() {
        removeTimeObserver()
        statusObserver?.invalidate()
        statusObserver = nil
        playerItem = nil
    }

    private func addTimeObserver(for item: AVPlayerItem) {
        removeTimeObserver()
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
}
