import OSLog
import SwiftUI

/// Нижняя панель распознавания: «Слушаю…», найденная песня и карточка
/// с действиями. Панель встроена в `NowPlayingView` оверлеем, а не вторым
/// `.sheet`: на iOS 15 вложенные sheet из уже открытого sheet теряются.
struct ShazamSheet: View {
    @ObservedObject var recognizer: ShazamRecognizer
    var onClose: () -> Void

    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var likes: LikeStore
    @Environment(\.contentTone) private var tone

    @State private var foundTrack: Track?
    @State private var isSearching = false
    @State private var searchFailed = false
    @State private var pulse = false

    private let logger = Logger(subsystem: "com.example.ymusic", category: "ShazamSheet")

    var body: some View {
        VStack(spacing: 16) {
            handle

            content
        }
        .padding(20)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(Color.black.opacity(0.35))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 18)
        .task(id: recognizer.state) {
            guard case .found(let match) = recognizer.state else { return }
            await searchInYandex(match)
        }
        .onDisappear {
            // Микрофон не должен оставаться занятым после закрытия панели.
            recognizer.stop()
        }
        .accessibilityElement(children: .contain)
    }

    private var handle: some View {
        Capsule()
            .fill(Color.white.opacity(0.25))
            .frame(width: 36, height: 5)
            .accessibilityHidden(true)
    }

    // MARK: - Состояния

    @ViewBuilder
    private var content: some View {
        switch recognizer.state {
        case .idle:
            messageBlock(
                systemImage: "mic.slash",
                title: "Микрофон выключен",
                text: "Запустите распознавание ещё раз."
            )
            actionRow(primary: "Слушать", primaryAction: start)
            closeButton

        case .listening:
            listeningBlock

        case .found(let match):
            foundBlock(match)

        case .notFound:
            messageBlock(
                systemImage: "questionmark.circle",
                title: "Не распознано",
                text: "Не получилось разобрать, что играет. Попробуйте ещё раз, ближе к колонке."
            )
            actionRow(primary: "Попробовать снова", primaryAction: start)
            closeButton

        case .failed(let message):
            messageBlock(
                systemImage: "exclamationmark.triangle",
                title: "Не получилось",
                text: message
            )
            actionRow(primary: "Повторить", primaryAction: start)
            closeButton
        }
    }

    private var listeningBlock: some View {
        VStack(spacing: 16) {
            ZStack {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .stroke(tone.primary.opacity(0.35 - Double(index) * 0.08), lineWidth: 1.5)
                        .frame(width: 70 + CGFloat(index) * 30, height: 70 + CGFloat(index) * 30)
                        .scaleEffect(pulse ? 1.12 : 0.92)
                        .opacity(pulse ? 0.2 : 0.7)
                        .animation(
                            .easeInOut(duration: 1.4)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.15),
                            value: pulse
                        )
                }

                Image(systemName: "mic.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(tone.primary)
            }
            .frame(height: 150)
            .onAppear { pulse = true }

            Text("Слушаю...")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tone.primary)

            Text("Держите телефон ближе к источнику звука")
                .font(.footnote)
                .foregroundStyle(tone.secondary)
                .multilineTextAlignment(.center)

            Button("Отмена") {
                recognizer.stop()
                onClose()
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(tone.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func foundBlock(_ match: ShazamRecognizer.Match) -> some View {
        VStack(spacing: 12) {
            Text("Распознано")
                .font(.caption.weight(.semibold))
                .foregroundStyle(tone.tertiary)

            Text(match.title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tone.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)

            if !match.artist.isEmpty {
                Text(match.artist)
                    .font(.footnote)
                    .foregroundStyle(tone.secondary)
                    .lineLimit(1)
            }

            if isSearching {
                HStack(spacing: 8) {
                    ProgressView().tint(tone.secondary)
                    Text("Ищем в Яндекс Музыке...")
                        .font(.footnote)
                        .foregroundStyle(tone.secondary)
                }
                .padding(.top, 4)
            } else if let track = foundTrack {
                trackCard(track)
            } else {
                Text(
                    searchFailed
                        ? "Поиск не ответил. Проверьте подключение и попробуйте снова."
                        : "В Яндекс Музыке этот трек не нашёлся."
                )
                .font(.footnote)
                .foregroundStyle(tone.secondary)
                .multilineTextAlignment(.center)

                actionRow(primary: "Искать снова", primaryAction: { retrySearch(match) })
            }

            closeButton
        }
    }

    private func trackCard(_ track: Track) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                CachedAsyncImage(url: track.artworkURL) {
                    ZStack {
                        Color.white.opacity(0.08)
                        Image(systemName: "music.note")
                            .foregroundStyle(.white.opacity(0.3))
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(tone.primary)
                        .lineLimit(2)

                    Text(track.artistLine)
                        .font(.caption)
                        .foregroundStyle(tone.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(10)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.07))
            }

            HStack(spacing: 10) {
                GlassButton("Слушать", systemImage: "play.fill", prominence: .prominent, fullWidth: true) {
                    Haptics.light()
                    player.play(track: track, in: [track])
                    onClose()
                }

                GlassButton("В лайки", systemImage: "heart", fullWidth: true) {
                    Haptics.light()
                    Task { _ = await likes.toggle(track) }
                }
            }
        }
    }

    // MARK: - Мелочи

    private func messageBlock(systemImage: String, title: String, text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(tone.secondary)

            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tone.primary)

            Text(text)
                .font(.footnote)
                .foregroundStyle(tone.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private func actionRow(primary: String, primaryAction: @escaping () -> Void) -> some View {
        GlassButton(primary, systemImage: "mic", prominence: .prominent, fullWidth: true) {
            primaryAction()
        }
    }

    private var closeButton: some View {
        Button("Закрыть") {
            recognizer.stop()
            onClose()
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(tone.tertiary)
    }

    private func start() {
        foundTrack = nil
        searchFailed = false
        Task { @MainActor in await recognizer.start() }
    }

    private func retrySearch(_ match: ShazamRecognizer.Match) {
        Task { @MainActor in await searchInYandex(match) }
    }

    @MainActor
    private func searchInYandex(_ match: ShazamRecognizer.Match) async {
        isSearching = true
        searchFailed = false
        foundTrack = nil
        defer { isSearching = false }

        let query = "\(match.title) \(match.artist)"
            .trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let result = try await APIManager.shared.search(text: query)
            guard !Task.isCancelled else { return }
            foundTrack = result.tracks.first
        } catch {
            guard !Task.isCancelled else { return }
            logger.error("Поиск распознанного: \(error.localizedDescription, privacy: .public)")
            searchFailed = true
        }
    }
}