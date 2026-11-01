import SwiftUI

/// 媒体库：最近播放（自动记录）+ 收藏的音乐（播放页红心收藏）。
struct LibraryView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        NavigationStack {
            Group {
                if store.recent.isEmpty && store.favorites.isEmpty {
                    ContentUnavailableView {
                        Label("还没有歌曲", systemImage: "music.note")
                    } description: {
                        Text("在搜索页播放的歌曲会自动出现在「最近播放」，播放页点击红心可收藏")
                    }
                } else {
                    libraryList
                }
            }
            .navigationTitle("资料库")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    private var libraryList: some View {
        List {
            if !store.favorites.isEmpty {
                Section {
                    ForEach(store.favorites) { song in
                        SongRow(song: song)
                    }
                } header: {
                    Label("收藏的音乐", systemImage: "heart.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                }
            }

            if !store.recent.isEmpty {
                Section {
                    ForEach(store.recent) { song in
                        SongRow(song: song)
                    }
                    .onDelete { offsets in
                        store.removeRecent(at: offsets)
                    }
                } header: {
                    Label("最近播放", systemImage: "clock")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}
