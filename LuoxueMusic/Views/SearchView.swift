import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var store: AppStore
    @State private var query = ""

    var body: some View {
        NavigationStack {
            Group {
                if store.isSearching {
                    ProgressView("搜索中…")
                } else if store.searchResults.isEmpty {
                    emptyState
                } else {
                    resultsList
                }
            }
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.large)
        }
        .searchable(text: $query, prompt: "歌曲 / 歌手")
        .onSubmit(of: .search) {
            Task { await store.search(query) }
        }
        .onChange(of: query) { _, newValue in
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Task { await store.search("") }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.magnifyingglass")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("输入关键词搜索歌曲")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Text("自带 QQ音乐 / 网易云 / 酷我平台曲库，导入音源用于播放")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultsList: some View {
        List {
            ForEach(store.searchResults) { song in
                SongRow(song: song)
            }
        }
        .listStyle(.plain)
    }
}

/// Apple Music 风格的歌曲行：**专辑封面** + 标题/歌手两行 + 尾部时长。
struct SongRow: View {
    let song: Song
    @EnvironmentObject private var store: AppStore

    private var artColors: [Color] {
        let seed = abs(song.songId.hashValue)
        let hue = Double(seed % 360) / 360.0
        return [
            Color(hue: hue, saturation: 0.55, brightness: 0.75),
            Color(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1.0), saturation: 0.7, brightness: 0.45)
        ]
    }

    /// 专辑封面：有 picUrl 用真实封面，否则按歌曲生成稳定的渐变占位图。
    @ViewBuilder private var artwork: some View {
        if !song.picUrl.isEmpty, let url = URL(string: song.picUrl) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    placeholderArt
                }
            }
        } else {
            placeholderArt
        }
    }

    private var placeholderArt: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(LinearGradient(colors: artColors, startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "music.note")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
        }
    }

    var body: some View {
        Button {
            store.play(song)
        } label: {
            HStack(spacing: 12) {
                artwork
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 3) {
                    Text(song.displayTitle)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(song.album.isEmpty ? song.displayArtist : "\(song.displayArtist) · \(song.album)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(timeString(song.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
    }

    private func timeString(_ t: Int) -> String {
        guard t > 0 else { return "--:--" }
        return "\(t / 60):\(String(format: "%02d", t % 60))"
    }
}
