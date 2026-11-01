import SwiftUI

/// Apple Music 风格的全屏播放页：大封面、细进度条、上一首/播放/下一首、歌词。
struct NowPlayingView: View {
    let song: Song
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var lyricLines: [LrcLine] = []

    // 进度条拖动状态：拖动期间显示拖动位置，松手才真正 seek，
    // 避免 0.5s 一次的进度观察器把滑块拉回去（拖动 bug 的根因）。
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0

    /// 封面占位渐变色（按歌名生成稳定观感的色调）。
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
            LinearGradient(colors: [
                artColors[1].opacity(0.55), Color(red: 0.06, green: 0.06, blue: 0.09)
            ], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 12)
                artwork
                Spacer(minLength: 12)
                titleBlock
                progressBlock
                controls
                lyricBlock
            }
            .padding(.horizontal, 24)
        }
        .tint(Color(red: 250 / 255.0, green: 35 / 255.0, blue: 59 / 255.0))
        .task { await loadLyric() }
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
            Text("正在播放")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer()
            Image(systemName: "ellipsis")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 40, height: 40)
                .glassEffect(.regular, in: Circle())
        }
        .padding(.top, 8)
    }

    private var artwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(LinearGradient(colors: artColors, startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "music.note")
                .font(.system(size: 72, weight: .light))
                .foregroundStyle(.white.opacity(0.85))
        }
        .aspectRatio(1, contentMode: .fit)
        .shadow(color: artColors[1].opacity(0.6), radius: 28, x: 0, y: 14)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(song.displayTitle)
                .font(.title2.bold())
                .lineLimit(1)
            Text(song.displayArtist)
                .font(.title3)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
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

    // MARK: - 歌词（Apple Music 风格：大字加粗左对齐、当前行高亮、自动滚动、点击跳转）

    private var lyricBlock: some View {
        LyricView(lines: lyricLines,
                  currentTime: store.player.currentTime) { store.seek(to: $0) }
            .padding(.top, 6)
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

/// 逐行歌词视图：当前行不透明、其余淡化，随播放自动滚动到当前行，点击任意行跳转播放。
private struct LyricView: View {
    let lines: [LrcLine]
    let currentTime: Double
    let seek: (Double) -> Void

    private var currentIdx: Int {
        LrcParser.currentIndex(of: lines, at: currentTime)
    }

    var body: some View {
        if lines.isEmpty {
            Text("暂无歌词")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 24)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(lines) { line in
                            Text(line.text.isEmpty ? "♪" : line.text)
                                .font(.title3.bold())
                                .foregroundStyle(line.id == currentIdx
                                                 ? AnyShapeStyle(.primary)
                                                 : AnyShapeStyle(.primary.opacity(0.35)))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .onTapGesture { seek(line.time) }
                                .id(line.id)
                        }
                    }
                    .padding(.vertical, 60)
                }
                .frame(maxHeight: 300)
                .mask(
                    LinearGradient(colors: [.clear, .black, .black, .clear],
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
