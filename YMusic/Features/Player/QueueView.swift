import SwiftUI

/// Очередь воспроизведения: текущий трек, «Дальше», удаление свайпом
/// и перестановка. Данные читаются из `AudioPlayer.queue`, поэтому экран
/// всегда совпадает с тем, что реально играет.
struct QueueView: View {
    @EnvironmentObject private var player: AudioPlayer
    @Environment(\.dismiss) private var dismiss
    @Environment(\.contentTone) private var tone

    @State private var isEditing = false
    @State private var showClearConfirmation = false

    private var upNext: [(index: Int, track: Track)] { player.queue.upNext }

    var body: some View {
        ZStack {
            LiquidBackdrop()

            VStack(spacing: 0) {
                header

                if player.queue.isEmpty {
                    VStack {
                        EmptyStateCard(
                            systemImage: "list.bullet",
                            title: "Очередь пуста",
                            message: "Запустите трек из каталога, поиска или «Мне нравится» — очередь соберётся сама."
                        )
                        .padding(20)

                        Spacer(minLength: 0)
                    }
                } else {
                    ScrollView(showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            currentSection

                            if !upNext.isEmpty {
                                upNextSection
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 4)
                        .padding(.bottom, 40)
                    }
                }
            }
        }
        .confirmationDialog(
            "Очистить очередь?",
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Оставить только текущий", role: .destructive) {
                Haptics.light()
                player.clearQueue(keepingCurrent: true)
                isEditing = false
            }

            Button("Отмена", role: .cancel) { }
        } message: {
            Text("Все треки после текущего будут удалены.")
        }
    }

    // MARK: - Шапка

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            GlassScreenHeader(
                title: "Очередь",
                subtitle: "\(player.queue.tracks.count) треков · \(upNext.count) дальше",
                onClose: { dismiss() }
            )

            HStack(spacing: 16) {
                if upNext.count > 1 {
                    Button(isEditing ? "Готово" : "Порядок") {
                        Haptics.selection()
                        withAnimation(.easeInOut(duration: 0.2)) { isEditing.toggle() }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tone.primary)
                }

                Button("Очистить всё") {
                    Haptics.selection()
                    showClearConfirmation = true
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(upNext.isEmpty ? tone.tertiary : Color.red.opacity(0.9))
                .disabled(upNext.isEmpty)

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    // MARK: - Секции

    private var currentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("СЕЙЧАС ИГРАЕТ")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(tone.tertiary)

            if let track = player.currentTrack,
               let index = player.queue.tracks.firstIndex(where: { $0.id == track.id }) {
                QueueRow(
                    track: track,
                    isCurrent: true,
                    onTap: { Haptics.selection() },
                    onDelete: { player.removeFromQueue(at: index) }
                )
            }
        }
    }

    private var upNextSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ДАЛЬШЕ")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(tone.tertiary)
                .padding(.top, 8)

            ForEach(Array(upNext.enumerated()), id: \.offset) { position, item in
                QueueRow(
                    track: item.track,
                    isCurrent: false,
                    isEditing: isEditing,
                    position: position,
                    total: upNext.count,
                    onTap: {
                        Haptics.light()
                        player.play(tracks: player.queue.tracks, startAt: item.index)
                    },
                    onDelete: {
                        Haptics.light()
                        player.removeFromQueue(at: item.index)
                    },
                    onMove: { from, to in
                        let destination = to > from ? to + 1 : to
                        player.moveInQueue(
                            fromOffsets: IndexSet(integer: from),
                            toOffset: destination
                        )
                    }
                )
            }
        }
    }
}

/// Строка очереди: обложка, название, исполнитель, длительность.
/// Свайп влево открывает удаление, в режиме «Порядок» вертикальный drag
/// переставляет трек. Оба жеста живут в одном `DragGesture` и разведены
/// по режиму, чтобы не конфликтовать с тапом.
private struct QueueRow: View {
    let track: Track
    let isCurrent: Bool
    var isEditing: Bool = false
    var position: Int = 0
    var total: Int = 0

    let onTap: () -> Void
    let onDelete: () -> Void
    var onMove: (Int, Int) -> Void = { _, _ in }

    @Environment(\.contentTone) private var tone
    @State private var swipeOffset: CGFloat = 0
    @State private var dragTranslation: CGFloat = 0

    private static let rowStep: CGFloat = 60

    var body: some View {
        ZStack(alignment: .trailing) {
            deleteBackground

            rowContent
                .background {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            isCurrent
                                ? tone.primary.opacity(0.12)
                                : Color.white.opacity(0.055)
                        )
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(
                            isCurrent ? tone.primary.opacity(0.35) : Color.white.opacity(0.08),
                            lineWidth: 1
                        )
                }
                .offset(x: min(swipeOffset, 0), y: dragTranslation)
                .zIndex(dragTranslation == 0 ? 0 : 1)
                .shadow(
                    color: dragTranslation == 0 ? .clear : .black.opacity(0.3),
                    radius: 10,
                    x: 0,
                    y: 6
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isEditing, swipeOffset == 0 else { return }
            onTap()
        }
        .gesture(dragGesture)
        .animation(.spring(response: 0.3, dampingFraction: 0.82), value: swipeOffset)
        .animation(.easeInOut(duration: 0.18), value: isEditing)
    }

    private var rowContent: some View {
        HStack(spacing: 12) {
            if isEditing {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tone.tertiary)
                    .frame(width: 20)
            }

            CachedAsyncImage(url: track.artworkURL) {
                ZStack {
                    Color.white.opacity(0.08)
                    Image(systemName: "music.note")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.system(size: 15, weight: isCurrent ? .bold : .medium))
                    .foregroundStyle(isCurrent ? tone.primary : tone.primary)
                    .lineLimit(1)

                Text(track.artistLine)
                    .font(.caption)
                    .foregroundStyle(tone.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if isCurrent {
                Image(systemName: "waveform")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tone.primary)
            } else {
                Text(track.durationText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(tone.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var deleteBackground: some View {
        HStack {
            Spacer()
            Image(systemName: "trash")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background { RoundedRectangle(cornerRadius: 16).fill(Color.red.opacity(0.8)) }
                .onTapGesture {
                    Haptics.light()
                    onDelete()
                }
                .padding(.trailing, 2)
        }
        .accessibilityHidden(true)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                if isEditing {
                    dragTranslation = value.translation.height
                    return
                }

                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                swipeOffset = max(-88, min(0, value.translation.width))
            }
            .onEnded { value in
                if isEditing {
                    let steps = Int((value.translation.height / Self.rowStep).rounded())
                    if steps != 0 {
                        let target = min(max(position + steps, 0), max(total - 1, 0))
                        if target != position {
                            Haptics.selection()
                            onMove(position, target)
                        }
                    }
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                        dragTranslation = 0
                    }
                    return
                }

                if value.translation.width < -60, abs(value.translation.width) > abs(value.translation.height) {
                    Haptics.light()
                    onDelete()
                }

                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                    swipeOffset = 0
                }
            }
    }
}

