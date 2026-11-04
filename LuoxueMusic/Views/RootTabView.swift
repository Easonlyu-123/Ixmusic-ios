import SwiftUI

struct RootTabView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showNowPlaying = false

    var body: some View {
        ZStack {
            backgroundView
            // 底部栏顺序对齐 Apple Music：资料库在左、搜索在最右，中间为「我的」（含音源/主题色设置）。
            TabView {
                LibraryView()
                    .tabItem { Label("资料库", systemImage: "music.note.list") }

                MineView()
                    .tabItem { Label("我的", systemImage: "person.crop.circle") }

                SearchView()
                    .tabItem { Label("搜索", systemImage: "magnifyingglass") }
            }
            .tint(store.accentColor)
        }
        .tint(store.accentColor)
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
        .fullScreenCover(isPresented: $showNowPlaying) {
            if let song = store.currentSong {
                NowPlayingView(song: song)
            }
        }
        .alert("播放失败", isPresented: Binding(
            get: { store.playbackNotice != nil },
            set: { if !$0 { store.playbackNotice = nil } }
        )) {
            Button("好", role: .cancel) { store.playbackNotice = nil }
        } message: {
            Text(store.playbackNotice ?? "")
        }
    }

    /// 深色 + 主题色光晕背景：液态玻璃需要背后有内容才能折射出质感。
    private var backgroundView: some View {
        let accent = store.accentColor
        return ZStack {
            Color(red: 0.04, green: 0.04, blue: 0.08)
            RadialGradient(
                colors: [accent.opacity(0.45), .clear],
                center: .topLeading, startRadius: 50, endRadius: 480
            )
            RadialGradient(
                colors: [Color.blue.opacity(0.40), .clear],
                center: .bottomTrailing, startRadius: 50, endRadius: 520
            )
            RadialGradient(
                colors: [accent.opacity(0.25), .clear],
                center: .init(x: 0.7, y: 0.35), startRadius: 40, endRadius: 360
            )
        }
        .ignoresSafeArea()
    }
}

/// 底部玻璃质感的迷你播放条（Apple Music 样式：胶囊形液态玻璃 + 封面 + 标题 + 播放/下一首）。
struct NowPlayingBar: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        HStack(spacing: 12) {
            // 专辑封面（圆形），无封面时用渐变占位。
            Group {
                if let pic = store.currentSong?.picUrl, !pic.isEmpty, let url = URL(string: pic) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        default:
                            placeholderCircle
                        }
                    }
                } else {
                    placeholderCircle
                }
            }
            .frame(width: 42, height: 42)
            .clipShape(Circle())

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
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        // 液态玻璃胶囊（Apple Music 迷你条：两端全圆），盖在 Tab 栏上方。
        .glassEffect(.regular, in: Capsule())
        .shadow(color: .black.opacity(0.35), radius: 14, x: 0, y: 6)
    }

    private var placeholderCircle: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(
                    colors: [Color.purple.opacity(0.8), Color.blue.opacity(0.7)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "music.note")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
        }
    }
}
