import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        NavigationStack {
            Group {
                if store.playlist.isEmpty {
                    ContentUnavailableView {
                        Label("还没有歌曲", systemImage: "music.note")
                    } description: {
                        Text("在搜索页播放的歌曲会加入这里")
                    }
                } else {
                    List {
                        ForEach(store.playlist) { song in
                            SongRow(song: song)
                        }
                        .onDelete { offsets in
                            store.playlist.remove(atOffsets: offsets)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("媒体库")
        }
    }
}
