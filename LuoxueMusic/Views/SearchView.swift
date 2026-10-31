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

struct SongRow: View {
    let song: Song
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Button {
            store.play(song)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(song.displayTitle)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    Text("\(song.displayArtist) · \(song.album)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(song.source)
                    .font(.caption2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .glassEffect(.regular, in: Capsule())
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}
