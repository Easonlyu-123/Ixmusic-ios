import SwiftUI

/// Apple Music 风格的全屏播放页：大封面、细进度条、上一首/播放/下一首、歌词。
struct NowPlayingView: View {
    let song: Song
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var lyric: String?

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
                Spacer(minLength: 8)
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
                get: { store.player.currentTime },
                set: { store.seek(to: $0) }
            ), in: 0...max(store.player.duration, 1))
            HStack {
                Text(timeString(store.player.currentTime))
                Spacer()
                Text("-" + timeString(max(store.player.duration - store.player.currentTime, 0)))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.top, 10)
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

    private var lyricBlock: some View {
        Group {
            if let lyric {
                ScrollView {
                    Text(lyric)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 150)
            } else {
                Text("暂无歌词")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(.top, 6)
    }

    private func loadLyric() async {
        lyric = await store.lyric(for: song)
    }

    private func timeString(_ t: Double) -> String {
        guard t.isFinite, t > 0 else { return "0:00" }
        let total = Int(t)
        let m = total / 60
        let s = total % 60
        return "\(m):\(String(format: "%02d", s))"
    }
}
