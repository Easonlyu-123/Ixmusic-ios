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
    /// 最近播放（媒体库「最近播放」），播放成功即记录。
    @Published var recent: [Song] = []
    /// 收藏的音乐，播放页可点击红心收藏。
    @Published var favorites: [Song] = []
    /// 主题色（「我的」页设置，持久化）。
    @Published var accentTheme: AppTheme

    var accentColor: Color { accentTheme.color }

    let player = AudioPlayer()
    private let runtime = SourceRuntime()
    private let sourcesKey = "luoxue.sources.v1"
    private let recentKey = "luoxue.recent.v1"
    private let favoritesKey = "luoxue.favorites.v1"
    private let accentKey = "luoxue.accent.v1"

    init() {
        let saved = UserDefaults.standard.string(forKey: accentKey)
            .flatMap(AppTheme.init(rawValue:)) ?? AppTheme.defaultTheme
        _accentTheme = Published(initialValue: saved)
        loadSources()
        loadLibrary()
    }

    /// 切换主题色并持久化。
    func setAccentTheme(_ theme: AppTheme) {
        accentTheme = theme
        UserDefaults.standard.set(theme.rawValue, forKey: accentKey)
    }

    // MARK: - 媒体库（最近播放 / 收藏）

    private func loadLibrary() {
        if let data = UserDefaults.standard.data(forKey: recentKey),
           let decoded = try? JSONDecoder().decode([Song].self, from: data) {
            recent = decoded
        }
        if let data = UserDefaults.standard.data(forKey: favoritesKey),
           let decoded = try? JSONDecoder().decode([Song].self, from: data) {
            favorites = decoded
        }
    }

    private func saveLibrary() {
        if let data = try? JSONEncoder().encode(recent) {
            UserDefaults.standard.set(data, forKey: recentKey)
        }
        if let data = try? JSONEncoder().encode(favorites) {
            UserDefaults.standard.set(data, forKey: favoritesKey)
        }
    }

    private func sameSong(_ a: Song, _ b: Song) -> Bool {
        a.source == b.source && a.songId == b.songId
    }

    /// 记录播放历史：去重置顶，上限 100 条。
    private func addRecent(_ song: Song) {
        recent.removeAll { sameSong($0, song) }
        recent.insert(song, at: 0)
        if recent.count > 100 { recent = Array(recent.prefix(100)) }
        saveLibrary()
    }

    /// 媒体库删除最近播放记录（按偏移集）。
    func removeRecent(at offsets: IndexSet) {
        recent.remove(atOffsets: offsets)
        saveLibrary()
    }

    /// 测试辅助：直接记录播放历史（play 成功时同样走 addRecent）。
    func recordRecentForTesting(_ song: Song) {
        addRecent(song)
    }

    func toggleFavorite(_ song: Song) {
        if let idx = favorites.firstIndex(where: { sameSong($0, song) }) {
            favorites.remove(at: idx)
        } else {
            favorites.insert(song, at: 0)
        }
        saveLibrary()
    }

    func isFavorite(_ song: Song) -> Bool {
        favorites.contains { sameSong($0, song) }
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
        sourcesServing(song.source).first ?? sources.first { $0.platform == song.source }
    }

    /// 洛雪模型：一个导入音源脚本可在 inited.sources 里声明服务多个平台；
    /// 返回所有「已启用且声明支持该 platform」的用户音源。
    func sourcesServing(_ platform: String) -> [MusicSource] {
        sources.filter { $0.enabled && $0.platform != "demo" }
            .filter { runtime.declaredPlatforms(source: $0)?.contains(platform) == true }
    }

    // MARK: - 搜索

    func search(_ query: String) async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            await MainActor.run { self.searchResults = [] }
            return
        }
        await MainActor.run { self.isSearching = true }

        // 洛雪官方模式：搜索由应用**自带平台音源**完成（网易云/酷我/QQ音乐），结果先上屏。
        async let builtInWy = BuiltInPlatforms.search(platform: "wy", keyword: q)
        async let builtInKw = BuiltInPlatforms.search(platform: "kw", keyword: q)
        async let builtInTx = BuiltInPlatforms.search(platform: "tx", keyword: q)
        let builtIn = await builtInTx + builtInWy + builtInKw
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
                let builtInHint = "（内置平台直链兜底也不可用）"
                playbackNotice = "「\(song.displayTitle)」暂无法播放\(detail)\(names)\n\(builtInHint)该歌曲可能是 VIP/版权歌曲，需可用音源支持。"
                return
            }
            playbackNotice = nil
            player.play(url: url)
            currentSong = song
            addRecent(song)
            if !playlist.contains(where: { $0.source == song.source && $0.songId == song.songId }) {
                playlist.append(song)
            }
            isPlaying = true
        }
    }

    /// 取链候选（洛雪模型）：声明支持本歌平台（song.source）的音源优先，
    /// 其余已启用音源作为兜底再试一次；演示源跳过。
    private func orderedCandidateSources(for song: Song) -> [MusicSource] {
        let serving = sourcesServing(song.source)
        let others = sources.filter { src in
            src.enabled && src.platform != "demo" && !serving.contains(where: { $0.id == src.id })
        }
        return serving + others
    }

    func lyric(for song: Song) async -> String? {
        // 优先用声明支持该平台的用户音源取歌词。
        for src in sourcesServing(song.source) {
            if let text = await runtime.getLyric(source: src, song: song), !text.isEmpty {
                return text
            }
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
