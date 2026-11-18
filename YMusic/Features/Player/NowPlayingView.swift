import SwiftUI

/// Полноэкранный плеер. Источник — тот же `AudioPlayer`, поэтому прогресс,
/// очередь и состояние совпадают с мини-плеером.
struct NowPlayingView: View {
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var likes: LikeStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.contentTone) private var tone

    @State private var scrubValue: Double?

    private var track: Track? { player.currentTrack }

    var body: some View {
        DynamicBackground(
            imageURL: track?.artworkURL,
            cacheKey: track?.artworkURL?.absoluteString ?? "now-playing",
            fallback: .brand
        ) {
            content
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            topBar

            ScrollView(showsIndicators: false) {
                VStack(spacing: 22) {
                    artwork
                    titles
                    progress
                    controls
                    actions
                    statusCard
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 30)
            }
        }
    }

    // MARK: - Верхняя панель

    private var topBar: some View {
        HStack {
            GlassIconButton("chevron.down", label: "Закрыть") {
                dismiss()
            }

            Spacer()

            Text("Сейчас играет")
                .font(.caption.weight(.semibold))
                .foregroundStyle(tone.tertiary)

            Spacer()

            Color.clear.frame(width: 40, height: 40)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: - Обложка и подписи

    private var artwork: some View {
        CachedAsyncImage(url: track?.artworkURL) {
            ZStack {
                Color.white.opacity(0.07)
                Image(systemName: "music.note")
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(.white.opacity(0.2))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 320)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.4), radius: 26, x: 0, y: 16)
        .padding(.top, 6)
    }

    private var titles: some View {
        VStack(spacing: 6) {
            Text(track?.title ?? "Ничего не играет")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(tone.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)

            Text(track?.artistLine ?? "Выберите трек в каталоге")
                .font(.subheadline)
                .foregroundStyle(tone.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Прогресс

    private var progress: some View {
        let total = max(player.duration, track?.duration ?? 0, 1)
        let shown = min(scrubValue ?? player.currentTime, total)

        return VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { shown },
                    set: { scrubValue = $0 }
                ),
                in: 0...total,
                onEditingChanged: { editing in
                    guard !editing else { return }
                    player.seek(to: scrubValue ?? player.currentTime)
                    scrubValue = nil
                }
            )
            .tint(tone.primary)

            HStack {
                Text(Self.timeText(shown))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(tone.tertiary)

                Spacer()

                Text(Self.timeText(total))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(tone.tertiary)
            }
        }
    }

    // MARK: - Кнопки

    private var controls: some View {
        HStack(spacing: 26) {
            Button {
                player.toggleShuffle()
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(player.queue.isShuffled ? tone.primary : tone.tertiary)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(PressableStyle(scale: 0.9))
            .accessibilityLabel("Перемешать")

            controlButton("backward.fill", label: "Предыдущий") {
                player.previous()
            }

            playPauseButton

            controlButton("forward.fill", label: "Следующий") {
                player.next()
            }

            Button {
                player.cycleRepeat()
            } label: {
                Image(systemName: repeatSymbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(player.queue.repeatMode == .off ? tone.tertiary : tone.primary)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(PressableStyle(scale: 0.9))
            .accessibilityLabel("Повтор")
        }
        .frame(maxWidth: .infinity)
    }

    private var playPauseButton: some View {
        Button {
            player.togglePlayPause()
        } label: {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay {
                        Circle().fill(Color.black.opacity(0.18))
                    }
                    .overlay {
                        Circle().strokeBorder(Color.white.opacity(0.28), lineWidth: 1)
                    }

                if player.isPlaying {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(tone.primary)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(tone.primary)
                        .offset(x: 2)
                }
            }
            .frame(width: 76, height: 76)
            .shadow(color: .black.opacity(0.35), radius: 18, x: 0, y: 10)
        }
        .buttonStyle(PressableStyle(scale: 0.94))
        .accessibilityLabel(player.isPlaying ? "Пауза" : "Играть")
    }

    private func controlButton(
        _ symbol: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(tone.primary)
                .frame(width: 48, height: 48)
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle(scale: 0.9))
        .accessibilityLabel(label)
    }

    private var repeatSymbol: String {
        player.queue.repeatMode == .one ? "repeat.1" : "repeat"
    }

    // MARK: - Действия

    @ViewBuilder
    private var actions: some View {
        if let track {
            HStack(spacing: 22) {
                LikeButton(
                    isLiked: likes.isLiked(track.id),
                    isPending: likes.isPending(track.id),
                    size: 44
                ) {
                    Task { _ = await likes.toggle(track) }
                }
                .accessibilityLabel(likes.isLiked(track.id) ? "Убрать из «Мне нравится»" : "Добавить в «Мне нравится»")
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Статус

    @ViewBuilder
    private var statusCard: some View {
        if case .failed(let error) = player.status {
            GlassCard(cornerRadius: 22, padding: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: error.isSubscriptionRequired ? "lock.fill" : "exclamationmark.triangle")
                            .font(.system(size: 14, weight: .semibold))

                        Text(error.isSubscriptionRequired ? "Требуется подписка" : "Не удалось воспроизвести")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundStyle(tone.primary)

                    Text(error.localizedDescription)
                        .font(.footnote)
                        .foregroundStyle(tone.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Это честный ответ сервера: клиент не обходит ограничения доступа.")
                        .font(.caption2)
                        .foregroundStyle(tone.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if let notice = player.notice {
            GlassCard(cornerRadius: 22, padding: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(tone.secondary)

                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(tone.secondary)
                }
            }
        }
    }

    // MARK: - Утилиты

    private static func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
