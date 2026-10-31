import SwiftUI

struct NowPlayingView: View {
    let song: Song
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var lyric: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    RoundedRectangle(cornerRadius: 28)
                        .fill(.ultraThinMaterial)
                        .frame(width: 220, height: 220)
                        .overlay {
                            Image(systemName: "music.note")
                                .font(.system(size: 80))
                                .foregroundStyle(.secondary)
                        }
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28))

                    Text(song.displayTitle)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                    Text(song.displayArtist)
                        .foregroundStyle(.secondary)

                    VStack(spacing: 6) {
                        Slider(value: Binding(
                            get: { store.player.currentTime },
                            set: { store.seek(to: $0) }
                        ), in: 0...max(store.player.duration, 1))
                        HStack {
                            Text(timeString(store.player.currentTime))
                            Spacer()
                            Text(timeString(store.player.duration))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 44) {
                        Button {
                            store.stopPlayback()
                            dismiss()
                        } label: {
                            Image(systemName: "stop.fill")
                                .font(.title)
                        }
                        Button {
                            store.togglePlay()
                        } label: {
                            Image(systemName: store.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 46))
                        }
                    }
                    .foregroundStyle(.primary)

                    if let lyric {
                        Text(lyric)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding()
                    } else {
                        Text("暂无歌词")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding()
            }
            .navigationTitle("正在播放")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .task { await loadLyric() }
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
