import AVFoundation
import SwiftUI

/// 基于 AVPlayer 的播放器封装，要求在主线程使用（@MainActor）。
/// 使用 iOS 17+ 的 @Observable，便于 SwiftUI 自动追踪嵌套的播放进度。
///
/// 关键修复：音频直链通过 `StreamingAssetLoader` 注入平台所需的 `Referer` 等请求头，
/// 否则网易云 / 酷我 / QQ 等 CDN 会 403，表现为「页面打开却放不出声音」。
@MainActor
@Observable
final class AudioPlayer {
    var isPlaying = false
    var currentTime: Double = 0
    var duration: Double = 0
    var currentURL: String?
    /// 播放失败原因（如 CDN 403 / 网络错误），用于透传给 UI 提示。
    var error: String?

    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var timeObserverToken: Any?
    private var statusObserver: NSKeyValueObservation?
    /// 必须强引用：loader 随 asset 的生命周期存活。
    private var loader: StreamingAssetLoader?

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
    func play(url: String, headers: [String: String] = [:]) {
        guard let u = URL(string: url) else { return }
        error = nil
        cleanupItem()
        let wrapped = StreamingAssetLoader.makeAsset(url: u, headers: headers)
        let item = AVPlayerItem(asset: wrapped.asset)
        self.loader = wrapped.loader
        self.playerItem = item
        player = AVPlayer(playerItem: item)
        addTimeObserver(for: item)
        observeStatus(item)
        player?.play()
        isPlaying = true
        currentURL = url
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
    }

    func seek(to seconds: Double) {
        let s = max(0, seconds.isFinite ? seconds : 0)
        player?.seek(to: CMTime(seconds: s, preferredTimescale: 600))
        // 立即回写进度，松手滑块不回跳，时间标签同步。
        currentTime = s
    }

    // MARK: - 内部

    private func cleanupItem() {
        removeTimeObserver()
        statusObserver?.invalidate()
        statusObserver = nil
        playerItem = nil
        // 先断开 session（打破 URLSession→delegate 循环引用），再释放 loader。
        loader?.invalidate()
        loader = nil
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
                    ?? "未知错误（可能是音源直链需要权限 / 已失效）"
                Task { @MainActor in self.error = reason }
            }
        }
    }
}
