import AVFoundation
import SwiftUI

/// 基于 AVPlayer 的播放器封装，要求在主线程使用（@MainActor）。
/// 使用 iOS 17+ 的 @Observable，便于 SwiftUI 自动追踪嵌套的播放进度。
@MainActor
@Observable
final class AudioPlayer {
    var isPlaying = false
    var currentTime: Double = 0
    var duration: Double = 0
    var currentURL: String?

    private var player: AVPlayer?
    private var timeObserverToken: Any?

    init() {
        configureAudioSession()
    }

    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            NSLog("LuoxueMusic audio session error: \(error)")
        }
    }

    func play(url: String) {
        guard let u = URL(string: url) else { return }
        removeTimeObserver()
        let item = AVPlayerItem(url: u)
        player = AVPlayer(playerItem: item)
        addTimeObserver(for: item)
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
        removeTimeObserver()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    func seek(to seconds: Double) {
        player?.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600))
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
}
