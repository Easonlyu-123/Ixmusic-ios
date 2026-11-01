import Foundation
import SwiftUI

/// 全局状态：音源管理、搜索、播放列表与当前播放。
@MainActor
final class AppStore: ObservableObject {
    @Published var sources: [MusicSource] = []
    @Published var searchText: String = ""
    @Published var searchResults: [Song] = []
    @Published var isSearching: Bool = false
    @Published var playlist: [Song] = []
    @Published var currentSong: Song?
    @Published var isPlaying: Bool = false
    /// 播放取链失败提示（洛雪模式：播放一律用导入的音源，失败时告知用户）。
    @Published var playbackNotice: String? = nil

    let player = AudioPlayer()
    private let runtime = SourceRuntime()
    private let sourcesKey = "luoxue.sources.v1"

    init() {
        loadSources()
    }

    // MARK: - 音源持久化

    func loadSources() {
        if let data = UserDefaults.standard.data(forKey: sourcesKey),
           let decoded = try? JSONDecoder().decode([MusicSource].self, from: data) {
            sources = decoded
        }
        if sources.isEmpty {
            sources = [BuiltInDemoSource.makeMusicSource()]
            saveSources()
        }
    }

    func saveSources() {
        if let data = try? JSONEncoder().encode(sources) {
            UserDefaults.standard.set(data, forKey: sourcesKey)
        }
    }

    func addSource(_ source: MusicSource) {
        sources.append(source)
        saveSources()
    }

    func removeSource(_ source: MusicSource) {
        sources.removeAll { $0.id == source.id }
        saveSources()
    }

    func toggleSourceEnabled(_ source: MusicSource) {
        if let idx = sources.firstIndex(where: { $0.id == source.id }) {
            sources[idx].enabled.toggle()
            saveSources()
        }
    }

    func source(for song: Song) -> MusicSource? {
        sources.first { $0.platform == song.source }
    }

    // MARK: - 搜索

    func search(_ query: String) async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            await MainActor.run { self.searchResults = [] }
            return
        }
        await MainActor.run { self.isSearching = true }

        // 洛雪官方模式：搜索由应用**自带平台音源**完成（网易云/酷我），结果先上屏。
        async let builtInWy = BuiltInPlatforms.search(platform: "wy", keyword: q)
        async let builtInKw = BuiltInPlatforms.search(platform: "kw", keyword: q)
        let builtIn = await builtInWy + builtInKw
        await MainActor.run { self.searchResults = builtIn }

        // 已启用的自定义音源若具备搜索能力（music/search），结果再并入列表。
        for src in sources where src.enabled && src.platform != "demo" {
            if let songs = await runtime.search(source: src, query: q), !songs.isEmpty {
                await MainActor.run { self.searchResults += songs }
            }
        }

        await MainActor.run { self.isSearching = false }
    }

    // MARK: - 播放

    /// 播放取链：平台对应音源 → 其他所有已启用音源（逐个尝试，洛雪行为：音源可跨平台取链）
    /// → 内置平台直链兜底（保证非 VIP 的内置平台歌曲始终可放；VIP/版权歌曲仍需音源）。
    /// 全部失败时把最后一个错误透传到弹窗，方便定位。
    func play(_ song: Song) {
        Task {
            var url: String?
            var lastError: String?
            var tried: [String] = []

            for src in orderedCandidateSources(for: song) {
                let (u, e) = await runtime.getUrlWithReport(source: src, song: song)
                if let u {
                    url = u
                    break
                }
                if let e { lastError = e }
                tried.append(src.name)
            }

            if url == nil {
                url = await BuiltInPlatforms.playUrl(platform: song.source, song: song)
            }

            guard let url else {
                let detail = lastError.map { "\n（音源返回：\($0)）" } ?? ""
                let names = tried.isEmpty ? "" : "\n已尝试音源：\(tried.joined(separator: "、"))"
                playbackNotice = "「\(song.displayTitle)」暂无法播放\(detail)\(names)\nVIP/版权歌曲需音源支持该平台。"
                return
            }
            playbackNotice = nil
            player.play(url: url)
            currentSong = song
            if !playlist.contains(where: { $0.source == song.source && $0.songId == song.songId }) {
                playlist.append(song)
            }
            isPlaying = true
        }
    }

    /// 取链候选：平台对应的音源优先，随后是其他已启用音源（跳过演示源）。
    private func orderedCandidateSources(for song: Song) -> [MusicSource] {
        let usable = sources.filter { $0.enabled && $0.platform != "demo" }
        var ordered: [MusicSource] = []
        if let matched = usable.first(where: { $0.platform == song.source }) {
            ordered.append(matched)
        }
        ordered += usable.filter { $0.id != ordered.first?.id }
        return ordered
    }

    func lyric(for song: Song) async -> String? {
        if let src = source(for: song),
           let text = await runtime.getLyric(source: src, song: song), !text.isEmpty {
            return text
        }
        if let fallback = sources.first(where: { $0.enabled && $0.platform != "demo" }),
           let text = await runtime.getLyric(source: fallback, song: song), !text.isEmpty {
            return text
        }
        return await BuiltInPlatforms.lyric(platform: song.source, song: song)
    }

    /// 播放列表导航（Apple Music 风格的上一首/下一首）。
    func playNext() {
        guard let cur = currentSong,
              let idx = playlist.firstIndex(where: { $0.source == cur.source && $0.songId == cur.songId }),
              idx + 1 < playlist.count else { return }
        play(playlist[idx + 1])
    }

    func playPrevious() {
        guard let cur = currentSong,
              let idx = playlist.firstIndex(where: { $0.source == cur.source && $0.songId == cur.songId }),
              idx > 0 else { return }
        play(playlist[idx - 1])
    }

    func togglePlay() {
        player.togglePlayPause()
        isPlaying = player.isPlaying
    }

    func stopPlayback() {
        player.stop()
        isPlaying = false
    }

    func seek(to seconds: Double) {
        player.seek(to: seconds)
    }
}
