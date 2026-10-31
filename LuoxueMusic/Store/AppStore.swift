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
        var collected: [Song] = []
        for src in sources where src.enabled {
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

    func play(_ song: Song) {
        Task {
            guard let src = source(for: song) else { return }
            if let url = await runtime.getUrl(source: src, song: song) {
                player.play(url: url)
                await MainActor.run {
                    self.currentSong = song
                    if !self.playlist.contains(where: { $0.source == song.source && $0.songId == song.songId }) {
                        self.playlist.append(song)
                    }
                    self.isPlaying = true
                }
            }
        }
    }

    func lyric(for song: Song) async -> String? {
        guard let src = source(for: song) else { return nil }
        return await runtime.getLyric(source: src, song: song)
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
