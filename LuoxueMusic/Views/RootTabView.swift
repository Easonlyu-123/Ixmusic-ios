import SwiftUI

struct RootTabView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showNowPlaying = false

    /// Apple Music 主题红。
    static let appleMusicRed = Color(red: 250 / 255.0, green: 35 / 255.0, blue: 59 / 255.0)

    var body: some View {
        ZStack {
            backgroundView
            // 底部栏顺序对齐 Apple Music：资料库在左、搜索在最右，中间为音源管理。
            TabView {
                LibraryView()
                    .tabItem { Label("资料库", systemImage: "music.note.list") }

                SourcesView()
                    .tabItem { Label("音源", systemImage: "server.rack") }

                SearchView()
                    .tabItem { Label("搜索", systemImage: "magnifyingglass") }
            }
            .tint(Self.appleMusicRed)
        }
        .tint(Self.appleMusicRed)
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

/// 底部玻璃质感的迷你播放条（Apple Music 样式：封面 + 标题 + 播放/下一首）。
struct NowPlayingBar: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 6)
                .fill(LinearGradient(
                    colors: [Color.purple.opacity(0.8), Color.blue.opacity(0.7)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 42, height: 42)
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(store.currentSong?.displayTitle ?? "")
                    .font(.subheadline.weight(.medium))
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
                    .font(.title3)
                    .foregroundStyle(.primary)
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
            Button {
                store.playNext()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title3)
                    .foregroundStyle(.primary)
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
    }
}
