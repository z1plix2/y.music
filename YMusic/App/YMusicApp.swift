import OSLog
import SwiftUI

extension Notification.Name {
    /// Виджет не может открыть sheet сам: он лишь дергает URL,
    /// а `MainView` по этому уведомлению показывает плеер.
    static let openNowPlaying = Notification.Name("openNowPlaying")
}

@main
struct YMusicApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
        }
    }
}

/// Переключает корневые экраны по состоянию сессии.
///
/// `@MainActor` на структуре: `AuthService` и `AudioPlayer` изолированы
/// на главном исполнителе, и без этого их создание в инициализаторе View
/// не проходит проверку Swift 6.
@MainActor
struct RootView: View {
    @StateObject private var auth = AuthService()

    // Для проверки управления без сети можно подменить источник:
    // `AudioPlayer(streamProvider: BundledDemoStreamProvider())`
    // и положить demo-track.m4a в бандл.
    @StateObject private var player = AudioPlayer()

    /// Сессии «Моей волны»: живут выше `MainView`, чтобы переживать
    /// пересоздание экрана и не терять сессию между открытиями плеера.
    @StateObject private var waveSession = WaveSessionController()

    @Environment(\.scenePhase) private var scenePhase

    /// Трек из deep link, пришедший до восстановления сессии.
    @State private var pendingTrackID: Int?

    private let logger = Logger(subsystem: "com.example.ymusic", category: "DeepLink")

    var body: some View {
        ZStack {
            switch auth.state {
            case .restoring:
                // Без transition снятие Splash было мгновенным: на 0.35 с
                // показывался голый фон, и переход выглядел миганием.
                SplashView()
                    .transition(.opacity)

            case .signedOut:
                LoginView()
                    .transition(.opacity)

            case .signedIn(let account):
                MainView(account: account)
                    .transition(.opacity.combined(with: .scale(scale: 1.02)))
            }
        }
        .environmentObject(auth)
        .environmentObject(player)
        .environmentObject(waveSession)
        .environmentObject(ListeningStatsStore.shared)
        .animation(.easeInOut(duration: 0.35), value: auth.state)
        .task {
            await auth.restore()
            resolvePendingDeepLink()
        }
        .onOpenURL { url in
            handleDeepLink(url)
        }
        .onChange(of: player.isConfigured) { ready in
            guard ready else { return }
            resolvePendingDeepLink()
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .background:
                // Играем дальше (UIBackgroundModes: audio), но состояние
                // очереди фиксируем: система может выгрузить процесс.
                player.persistNow()

            case .inactive:
                // Если очередь пуста, держать аудиосессию и пульт незачем.
                if player.queue.isEmpty {
                    player.teardown()
                }

            case .active:
                // Возврат из фона: восстановить remote-команды, если очередь
                // непустая (teardown мог их снять на .inactive).
                player.reinstallRemoteIfNeeded()

            @unknown default:
                break
            }
        }
    }

    // MARK: - Deep link

    /// `ymusic://track/{id}` из QR-кода открытки.
    ///
    /// Трек ищем в уже загруженной очереди и недавних, иначе догружаем точечно
    /// (`/tracks?track-ids=`). Если сессия ещё восстанавливается, id ждёт
    /// в `pendingTrackID` — на холодном старте `onOpenURL` приходит раньше
    /// готовности плеера.
    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "ymusic" else { return }

        if url.host == "nowplaying" {
            guard case .signedIn = auth.state else { return }
            NotificationCenter.default.post(name: .openNowPlaying, object: nil)
            return
        }

        guard url.host == "track" else { return }

        let rawID = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let trackID = Int(rawID) else {
            logger.debug("Ссылка без числового id: \(url.absoluteString, privacy: .public)")
            return
        }

        guard case .signedIn = auth.state else {
            pendingTrackID = trackID
            return
        }

        openTrack(trackID: trackID)
    }

    private func resolvePendingDeepLink() {
        guard let trackID = pendingTrackID else { return }
        pendingTrackID = nil
        openTrack(trackID: trackID)
    }

    private func openTrack(trackID: Int) {
        guard player.isConfigured else {
            pendingTrackID = trackID
            return
        }

        if let existing = player.queue.tracks.first(where: { $0.id == trackID }) {
            player.play(track: existing, in: player.queue.tracks)
            return
        }

        if let recent = player.recents.first(where: { $0.id == trackID }) {
            player.play(track: recent, in: [recent])
            return
        }

        Task { @MainActor in
            do {
                let tracks = try await APIManager.shared.tracks(ids: [trackID])
                guard let track = tracks.first else {
                    logger.debug("Трек \(trackID) не найден")
                    return
                }
                player.play(track: track, in: [track])
            } catch {
                logger.error("Deep link: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

/// Экран на время чтения токена из Keychain (десятки миллисекунд).
private struct SplashView: View {
    var body: some View {
        ZStack {
            LiquidBackdrop()

            VStack(spacing: 20) {
                Image(systemName: "waveform")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.white)

                ProgressView()
                    .tint(.white.opacity(0.8))
            }
        }
    }
}
