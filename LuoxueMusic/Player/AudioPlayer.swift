import AVFoundation
import SwiftUI

/// 基于 AVPlayer 的播放器封装，要求在主线程使用（@MainActor）。
///
/// 播放机制（对齐洛雪移动端的做法）：
/// 1. 优先用带请求头（Referer 等）的 `AVURLAsset` 直接**流式播放**——这是 iOS 上最稳的方式，
///    不需要把整首歌下载完再播，也不需要脆弱的自定义 scheme 拦截。
/// 2. 若流式因部分 CDN 需要逐请求头部而失败，自动回退到「带头部下载到本地，再播本地文件」。
@MainActor
@Observable
final class AudioPlayer {
    var isPlaying = false
    var currentTime: Double = 0
    var duration: Double = 0
    var currentURL: String?
    /// 是否正在加载音频（流式起播前的缓冲 / 回退下载）。
    var isLoading = false
    /// 播放失败原因，用于透传给 UI 提示。
    var error: String?

    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var timeObserverToken: Any?
    private var statusObserver: NSKeyValueObservation?
    /// 当前播放请求（流式失败后的本地回退下载用）。
    private var pendingRequest: (url: URL, headers: [String: String])?

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

    /// 播放音频直链；headers 为各平台 CDN 所需的请求头（Referer 等）。
    ///
    /// 流程：带头部流式播放 →（失败）回退到「下载到本地再播放」。
    func play(url: String, headers: [String: String] = [:]) {
        guard let u = URL(string: url), (u.scheme == "http" || u.scheme == "https") else {
            error = "无效的音频地址"
            return
        }
        error = nil
        isLoading = true
        pendingRequest = (u, headers)
        startStreaming(url: u, headers: headers)
    }

    /// 用带请求头的 AVURLAsset 直接流式播放（最稳，无需下载）。
    private func startStreaming(url: URL, headers: [String: String]) {
        // 注意：当前 SDK 未暴露 AVURLAssetHTTPHeaderFieldsKey 符号，改用其字符串字面量。
        let options: [String: Any]? = headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers]
        let asset = AVURLAsset(url: url, options: options)
        let item = AVPlayerItem(asset: asset)
        playerItem = item
        player = AVPlayer(playerItem: item)
        addTimeObserver(for: item)
        observeStreamStatus(item)
        isLoading = false
        player?.play()
        isPlaying = true
        currentURL = url.absoluteString
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

    /// 监听流式条目的状态：失败时回退到本地下载播放。
    private func observeStreamStatus(_ item: AVPlayerItem) {
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
            guard let self else { return }
            if observed.status == .failed {
                let reason = (observed.error as NSError?)?.localizedDescription
                    ?? "未知错误（可能是该直链失效或需要登录 Cookie）"
                Task { @MainActor in await self.fallbackToLocal(reason: reason) }
            }
        }
    }

    /// 流式失败后的兜底：带头部把音频下载到本地，再用 AVPlayer 播放本地文件。
    private func fallbackToLocal(reason: String) async {
        guard let (url, headers) = pendingRequest else {
            self.error = "播放失败：\(reason)"
            return
        }
        // 已被新的播放请求取代，放弃本次回退。
        let expected = url
        isLoading = true
        do {
            let local = try await downloadToLocal(url, headers: headers)
            guard pendingRequest?.url == expected else { return }
            let item = AVPlayerItem(url: local)
            playerItem = item
            player = AVPlayer(playerItem: item)
            addTimeObserver(for: item)
            // 本地播放若仍失败，直接报错（不再二次回退）。
            statusObserver = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
                guard let self, observed.status == .failed else { return }
                let r = (observed.error as NSError?)?.localizedDescription ?? "未知错误"
                Task { @MainActor in self.error = "播放失败：\(r)" }
            }
            player?.play()
            isPlaying = true
            error = nil
        } catch {
            self.error = "播放失败：\(reason)；本地回退也失败：\(error.localizedDescription)"
        }
        isLoading = false
    }

    /// 带请求头把音频下载到本地临时文件（流式失败时的回退路径）。
    private func downloadToLocal(_ url: URL, headers: [String: String]) async throws -> URL {
        var req = URLRequest(url: url, timeoutInterval: 60)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(domain: "LuoxueMusic", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "下载返回 HTTP \(http.statusCode)"])
        }
        let ext = url.pathExtension.isEmpty ? "mp3" : url.pathExtension
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lx_\(UUID().uuidString).\(ext)")
        try data.write(to: tmp)
        return tmp
    }
}
