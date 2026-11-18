import SwiftUI

/// Компактная полоса над нижним краем экрана. Показывается, когда в очереди
/// есть трек; тап открывает полноэкранный плеер.
struct MiniPlayerView: View {
    @EnvironmentObject private var player: AudioPlayer
    @Environment(\.contentTone) private var tone

    let onOpen: () -> Void

    var body: some View {
        Group {
            if let track = player.currentTrack {
                content(track)
            }
        }
    }

    private func content(_ track: Track) -> some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: track.artworkURL) {
                ZStack {
                    Color.white.opacity(0.08)
                    Image(systemName: "music.note")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tone.primary)
                    .lineLimit(1)

                Text(subtitle(for: track))
                    .font(.caption2)
                    .foregroundStyle(tone.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: playSymbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(tone.primary)
                    .frame(width: 38, height: 38)
                    .contentShape(Circle())
            }
            .buttonStyle(PressableStyle(scale: 0.9))
            .accessibilityLabel(player.isPlaying ? "Пауза" : "Играть")
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .glassPanel(cornerRadius: 22)
        .overlay(alignment: .bottom) {
            progressBar
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
        }
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture(perform: onOpen)
        .accessibilityElement(children: .contain)
        .accessibilityHint("Открыть плеер")
    }

    private var progressBar: some View {
        GeometryReader { proxy in
            let fraction = player.duration > 0
                ? min(max(player.currentTime / player.duration, 0), 1)
                : 0

            ZStack(alignment: .leading) {
                Capsule().fill(tone.primary.opacity(0.16))
                Capsule()
                    .fill(tone.primary.opacity(0.75))
                    .frame(width: max(2, proxy.size.width * fraction))
            }
        }
        .frame(height: 2)
        .allowsHitTesting(false)
    }

    private var playSymbol: String {
        if player.isBuffering && !player.isPlaying {
            return "hourglass"
        }
        return player.isPlaying ? "pause.fill" : "play.fill"
    }

    private func subtitle(for track: Track) -> String {
        if player.notice != nil {
            return "Превью · \(track.artistLine)"
        }
        return track.artistLine
    }
}
