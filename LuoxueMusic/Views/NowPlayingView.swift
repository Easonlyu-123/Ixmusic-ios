import SwiftUI

/// Apple Music 风格的全屏播放页：大封面 / 整页歌词两态切换（点击封面进入歌词），
/// 真实专辑封面、细进度条、上一首/播放/下一首、收藏。
struct NowPlayingView: View {
    let song: Song
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var lyricLines: [LrcLine] = []
    /// false = 封面页；true = 整页歌词（Apple Music 行为：点封面进入，点标题返回）。
    @State private var showLyrics = false

    // 进度条拖动状态：拖动期间显示拖动位置，松手才真正 seek，
    // 避免 0.5s 一次的进度观察器把滑块拉回去（拖动 bug 的根因）。
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0

    /// 封面占位渐变色（按歌曲生成稳定观感的色调）。
    private var artColors: [Color] {
        let seed = abs(song.songId.hashValue)
        let hue = Double(seed % 360) / 360.0
        let top = Color(hue: hue, saturation: 0.55, brightness: 0.78)
        let bottom = Color(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1.0),
                           saturation: 0.72, brightness: 0.42)
        return [top, bottom]
    }

    var body: some View {
        ZStack {
            blurredBackdrop

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 8)
                titleBlock
                if showLyrics {
                    fullLyricPage
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.92, anchor: .top)).combined(with: .move(edge: .trailing)),
                            removal: .opacity.combined(with: .scale(scale: 0.95, anchor: .top))))
                } else {
                    artwork
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.95)),
                            removal: .opacity.combined(with: .scale(scale: 1.06, anchor: .top))))
                    progressBlock
                    controls
                }
            }
            .padding(.horizontal, 24)
        }
        .tint(store.accentColor)
        // 钉死整页尺寸，避免专辑图加载后把页面「撑大」导致溢出裁切。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await loadLyric() }
        .alert("播放失败", isPresented: Binding(
            get: { store.playbackNotice != nil },
            set: { if !$0 { store.playbackNotice = nil } }
        )) {
            Button("好", role: .cancel) { store.playbackNotice = nil }
        } message: {
            Text(store.playbackNotice ?? "")
        }
    }

    // MARK: - 背景：封面放大模糊（歌词页更浓，Apple Music 的模糊底色效果）

    private var blurredBackdrop: some View {
        ZStack {
            LinearGradient(colors: [
                artColors[1].opacity(0.55), Color(red: 0.05, green: 0.05, blue: 0.08)
            ], startPoint: .top, endPoint: .bottom)
            if !song.picUrl.isEmpty, let url = URL(string: song.picUrl) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    }
                }
                // 约束尺寸，避免原图固有尺寸把整页「撑大」造成溢出裁切。
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .blur(radius: 72)
                .opacity(showLyrics ? 0.5 : 0.32)
                .scaleEffect(1.25)
            }
            Color.black.opacity(showLyrics ? 0.35 : 0.1)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.45), value: showLyrics)
    }

    // MARK: - 子视图

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
                    .glassEffect(.regular, in: Circle())
            }
            Spacer()
            // Apple Music：歌词页点标题区返回封面。
            Button {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
                    showLyrics = false
                }
            } label: {
                VStack(spacing: 2) {
                    Text("正在播放")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text(song.album.isEmpty ? song.displayArtist : song.album)
                        .font(.footnote)
                        .foregroundStyle(.primary.opacity(0.8))
                        .lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "ellipsis")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 40, height: 40)
                .glassEffect(.regular, in: Circle())
        }
        .padding(.top, 8)
    }

    /// 专辑封面（真实封面 + 占位渐变兜底），点击进入整页歌词。
    private var artwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(LinearGradient(colors: artColors, startPoint: .topLeading, endPoint: .bottomTrailing))
            if !song.picUrl.isEmpty, let url = URL(string: song.picUrl) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Image(systemName: "music.note")
                            .font(.system(size: 72, weight: .light))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 72, weight: .light))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: artColors[1].opacity(0.6), radius: 28, x: 0, y: 14)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
                showLyrics = true
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // Apple Music：封面右下角的「歌词」提示气泡。
            Text("歌词")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .glassEffect(.regular, in: Capsule())
                .foregroundStyle(.primary)
                .padding(10)
        }
    }

    private var titleBlock: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(song.displayTitle)
                    .font(.title2.bold())
                    .lineLimit(1)
                Text(song.displayArtist)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            // 收藏（Apple Music：标题右侧红心）。
            Button {
                store.toggleFavorite(song)
            } label: {
                Image(systemName: store.isFavorite(song) ? "heart.fill" : "heart")
                    .font(.title3)
                    .foregroundStyle(store.isFavorite(song) ? store.accentColor : Color.primary)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    private var progressBlock: some View {
        VStack(spacing: 4) {
            Slider(value: Binding(
                get: { isScrubbing ? scrubValue : store.player.currentTime },
                set: { scrubValue = $0 }
            ), in: 0...max(store.player.duration, 1)) { editing in
                if editing {
                    isScrubbing = true
                    scrubValue = store.player.currentTime
                } else {
                    // 松手才 seek 一次；拖动过程中不 seek、不被观察器回写。
                    store.seek(to: scrubValue)
                    store.player.currentTime = scrubValue
                    isScrubbing = false
                }
            }
            HStack {
                Text(timeString(displayTime))
                Spacer()
                Text("-" + timeString(max(store.player.duration - displayTime, 0)))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.top, 10)
    }

    private var displayTime: Double {
        isScrubbing ? scrubValue : store.player.currentTime
    }

    private var controls: some View {
        HStack(spacing: 48) {
            Button {
                store.playPrevious()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.title2)
            }
            Button {
                store.togglePlay()
            } label: {
                Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 40))
            }
            Button {
                store.playNext()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title2)
            }
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    // MARK: - 整页歌词（占满封面区到进度条之间）

    private var fullLyricPage: some View {
        LyricView(lines: lyricLines,
                  currentTime: store.player.currentTime) { store.seek(to: $0) }
    }

    private func loadLyric() async {
        let text = await store.lyric(for: song) ?? ""
        await MainActor.run { self.lyricLines = LrcParser.parse(text) }
    }

    private func timeString(_ t: Double) -> String {
        guard t.isFinite, t > 0 else { return "0:00" }
        let total = Int(t)
        let m = total / 60
        let s = total % 60
        return "\(m):\(String(format: "%02d", s))"
    }
}

/// 逐行歌词视图：当前行不透明加粗、其余淡化，随播放自动滚动到当前行，点击任意行跳转播放。
/// 可用空间紧张时（封面页内嵌）自动压缩，整页歌词时占满剩余空间。
private struct LyricView: View {
    let lines: [LrcLine]
    let currentTime: Double
    let seek: (Double) -> Void

    private var currentIdx: Int {
        LrcParser.currentIndex(of: lines, at: currentTime)
    }

    var body: some View {
        if lines.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "quote.opening")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text("暂无歌词")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(lines) { line in
                            let isCurrent = line.id == currentIdx
                            Text(line.text.isEmpty ? "♪" : line.text)
                                .font(isCurrent ? .title.bold() : .title2.bold())
                                .foregroundStyle(isCurrent
                                                 ? AnyShapeStyle(.primary)
                                                 : AnyShapeStyle(.primary.opacity(0.35)))
                                .scaleEffect(isCurrent ? 1.0 : 0.96, anchor: .leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .onTapGesture { seek(line.time) }
                                .id(line.id)
                                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isCurrent)
                        }
                    }
                    .padding(.vertical, 60)
                    .padding(.horizontal, 2)
                }
                .mask(
                    LinearGradient(colors: [.clear, .black, .black, .black, .clear],
                                   startPoint: .top, endPoint: .bottom)
                )
                .onChange(of: currentTime) { _, t in
                    let idx = LrcParser.currentIndex(of: lines, at: t)
                    guard idx >= 0 else { return }
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(idx, anchor: .center)
                    }
                }
            }
        }
    }
}
