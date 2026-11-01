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

        // 洛雪官方模式：搜索由应用**自带平台音源**完成（网易云/酷我）。
        async let builtInWy = BuiltInPlatforms.search(platform: "wy", keyword: q)
        async let builtInKw = BuiltInPlatforms.search(platform: "kw", keyword: q)
        var collected = await builtInWy + builtInKw

        // 已启用的自定义音源若具备搜索能力（music/search），结果并入列表。
        for src in sources where src.enabled && src.platform != "demo" {
            if let songs = await runtime.search(source: src, query: q) {
                collected.append(contentsOf: songs)
            }
        }

        await MainActor.run {
            self.searchResults = collected
            self.isSearching = false
        }
    }

    // MARK: - 播放

    /// 播放取链（按用户要求，洛雪模式）：**只用导入的音源**。
    /// 顺序：平台对应的音源 → 其他已启用的音源（洛雪行为：音源可跨平台取链）。
    /// 不使用内置平台直链兜底——VIP/版权歌曲内置接口拿不到可用链接，交由音源处理。
    func play(_ song: Song) {
        Task {
            var url: String?
            if let src = source(for: song) {
                url = await runtime.getUrl(source: src, song: song)
            }
            if url == nil, let src = sources.first(where: { $0.enabled && $0.platform != "demo" }) {
                url = await runtime.getUrl(source: src, song: song)
            }
            guard let url else {
                playbackNotice = "无法通过已导入音源获取「\(song.displayTitle)」的播放链接，请到「音源」确认音源已启用且支持该平台。"
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
