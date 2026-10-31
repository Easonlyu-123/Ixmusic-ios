import SwiftUI

struct RootTabView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showNowPlaying = false

    var body: some View {
        ZStack {
            backgroundView
            TabView {
                SearchView()
                    .tabItem { Label("搜索", systemImage: "magnifyingglass") }

                LibraryView()
                    .tabItem { Label("媒体库", systemImage: "music.note.list") }

                SourcesView()
                    .tabItem { Label("音源", systemImage: "server.rack") }
            }
        }
        .overlay(alignment: .bottom) {
            if store.currentSong != nil {
                Button {
                    showNowPlaying = true
                } label: {
                    NowPlayingBar()
                        .padding(.horizontal)
                        .padding(.bottom, 76)
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(isPresented: $showNowPlaying) {
            if let song = store.currentSong {
                NowPlayingView(song: song)
            }
        }
    }

    /// 深色 + 彩色光晕背景：液态玻璃需要背后有内容才能折射出质感。
    private var backgroundView: some View {
        ZStack {
            Color(red: 0.04, green: 0.04, blue: 0.08)
            RadialGradient(
                colors: [Color.purple.opacity(0.45), .clear],
                center: .topLeading, startRadius: 50, endRadius: 480
            )
            RadialGradient(
                colors: [Color.blue.opacity(0.40), .clear],
                center: .bottomTrailing, startRadius: 50, endRadius: 520
            )
            RadialGradient(
                colors: [Color.pink.opacity(0.28), .clear],
                center: .init(x: 0.7, y: 0.35), startRadius: 40, endRadius: 360
            )
        }
        .ignoresSafeArea()
    }
}

/// 底部玻璃质感的迷你播放条。
struct NowPlayingBar: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.currentSong?.displayTitle ?? "")
                    .font(.headline)
                    .lineLimit(1)
                Text(store.currentSong?.displayArtist ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                store.togglePlay()
            } label: {
                Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .foregroundStyle(.primary)
                    .frame(width: 40, height: 40)
                    .glassEffect(.regular, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
    }
}
