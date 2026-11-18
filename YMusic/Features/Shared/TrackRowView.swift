import SwiftUI

/// Строка трека, общая для каталога, «Мне нравится» и плейлиста.
///
/// Лавка/плей-зона разделены: тап по информации играет трек через `onTap`,
/// сердечко остаётся отдельной кнопкой. Так не возникает вложенных `Button`,
/// которые в SwiftUI перехватывают тапы друг у друга.
struct TrackRowView: View {
    let track: Track
    var isCurrent: Bool = false
    var isPlaying: Bool = false
    var showsLike: Bool = true
    /// Тап по строке (кроме сердечка и длительности).
    var onTap: (() -> Void)? = nil
    /// Вызывается после успешного снятия лайка: «Мне нравится» убирает строку.
    var onUnlike: ((Track) -> Void)? = nil

    @EnvironmentObject private var player: AudioPlayer
    @Environment(\.contentTone) private var tone

    @State private var sharePayload: SharePayload?
    @State private var isPreparingShare = false

    /// Тап по «К артисту» в меню. Не задан — пункт скрыт: у трека из
    /// истории id артиста равен 0, ручки для него нет.
    var onOpenArtist: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            Button {
                Haptics.light()
                onTap?()
            } label: {
                HStack(spacing: 12) {
                    cover

                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title)
                            .font(.system(size: 15, weight: isCurrent ? .semibold : .medium))
                            .foregroundStyle(tone.primary)
                            .lineLimit(1)

                        Text(track.artistLine)
                            .font(.caption)
                            .foregroundStyle(tone.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(onTap == nil)
            .accessibilityLabel("\(track.title), \(track.artistLine)")

            if showsLike {
                RowLikeButton(track: track, onUnlike: onUnlike)
            }

            Text(track.durationText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(tone.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .contextMenu { contextMenuContent }
        .sheet(item: $sharePayload) { payload in
            ActivityView(items: payload.items)
        }
    }

    // MARK: - Контекстное меню

    @ViewBuilder
    private var contextMenuContent: some View {
        Button {
            Haptics.selection()
            player.playNext(track)
        } label: {
            Label("Играть следующим", systemImage: "text.line.first.and.arrowtriangle.forward")
        }

        Button {
            Haptics.selection()
            player.addToQueue(track)
        } label: {
            Label("В очередь", systemImage: "text.badge.plus")
        }

        Divider()

        if let onOpenArtist {
            Button {
                Haptics.selection()
                onOpenArtist()
            } label: {
                Label("К артисту", systemImage: "person")
            }
        }

        TrackLikeMenuButton(track: track)

        Button {
            prepareShare()
        } label: {
            Label(
                isPreparingShare ? "Готовим открытку..." : "Поделиться",
                systemImage: "square.and.arrow.up"
            )
        }
        .disabled(isPreparingShare)
    }

    private func prepareShare() {
        guard !isPreparingShare else { return }
        isPreparingShare = true

        Task { @MainActor in
            let image = await ShareCardRenderer.image(for: track)
            isPreparingShare = false
            sharePayload = SharePayload(items: [image])
        }
    }

    private var cover: some View {
        ZStack {
            CachedAsyncImage(url: track.artworkURL) {
                ZStack {
                    Color.white.opacity(0.08)
                    Image(systemName: "music.note")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white.opacity(0.25))
                }
            }
            .frame(width: 52, height: 52)

            if isCurrent {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black.opacity(0.45))

                Image(systemName: isPlaying ? "waveform" : "pause.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Лайк

/// Сердечко строки. Подписка на `LikeStore` живёт здесь, а не в
/// `TrackRowView`: тап по лайку обновляет только кнопку, а не строку
/// с обложкой и текстами.
private struct RowLikeButton: View {
    let track: Track
    var onUnlike: ((Track) -> Void)?

    @EnvironmentObject private var likes: LikeStore

    var body: some View {
        LikeButton(
            isLiked: likes.isLiked(track.id),
            isPending: likes.isPending(track.id)
        ) {
            Task {
                let nowLiked = await likes.toggle(track)
                if !nowLiked {
                    onUnlike?(track)
                }
            }
        }
    }
}

/// Пункт контекстного меню: подписывается отдельно, чтобы текст и иконка
/// были актуальны без перерисовки всей строки.
private struct TrackLikeMenuButton: View {
    let track: Track

    @EnvironmentObject private var likes: LikeStore

    var body: some View {
        Button {
            Task { _ = await likes.toggle(track) }
        } label: {
            Label(
                likes.isLiked(track.id) ? "Убрать из лайков" : "В лайки",
                systemImage: likes.isLiked(track.id) ? "heart.slash" : "heart"
            )
        }
    }
}
