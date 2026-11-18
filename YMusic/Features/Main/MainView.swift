import Combine
import OSLog
import SwiftUI
import UIKit

/// Главный экран: фон из обложки текущего трека (или первой обложки каталога),
/// шапка аккаунта, hero-карточка «Моя волна», секции каталога и мини-плеер.
///
/// `LikeStore` создаётся здесь: он привязан к `userID` аккаунта и доступен
/// всему поддереву (каталог, «Мне нравится», плейлист, поиск, плеер) через
/// environment.
struct MainView: View {
    let account: Account
    /// Плеер приходит значением, а не через `@EnvironmentObject`: иначе любой
    /// тик `currentTime` (2 раза в секунду) перерисовывал бы весь экран.
    let player: AudioPlayer

    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var waveSession: WaveSessionController

    @StateObject private var catalog: CatalogViewModel
    @StateObject private var likes: LikeStore
    @StateObject private var wave: WaveViewModel
    @State private var route: MainRoute?
    /// Отложенный переход NowPlaying → артист: сначала закрываем плеер,
    /// потом открываем артиста. Храним задачу, чтобы отменить её при уходе.
    @State private var pendingRouteTask: Task<Void, Never>?
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?

    private let logger = Logger(subsystem: "com.example.ymusic", category: "MainView")

    @MainActor
    init(account: Account, player: AudioPlayer) {
        self.account = account
        self.player = player
        _catalog = StateObject(wrappedValue: CatalogViewModel(userID: account.uid))
        _likes = StateObject(wrappedValue: LikeStore(userID: account.uid))
        _wave = StateObject(wrappedValue: WaveViewModel())
    }

    var body: some View {
        DynamicBackground(
            imageURL: backgroundImageURL,
            cacheKey: backgroundKey,
            fallback: .brand
        ) {
            ZStack(alignment: .bottom) {
                MainScrollContent(
                    account: account,
                    player: player,
                    catalog: catalog,
                    wave: wave,
                    route: $route
                )

                MiniPlayerHost(player: player) {
                    route = .player
                }
            }
        }
        .environmentObject(likes)
        .sheet(item: $route) { presented in
            destination(for: presented, onClose: { route = nil })
                .environmentObject(auth)
                .environmentObject(player)
                .environmentObject(likes)
                .environmentObject(waveSession)
                .environmentObject(AppSettingsStore.shared)
                .environmentObject(ListeningStatsStore.shared)
        }
        .onAppear {
            catalog.onSessionExpired = {
                Task {
                    player.resetForSignOut()
                    await auth.signOut()
                }
            }
        }
        .onDisappear {
            pendingRouteTask?.cancel()
            pendingRouteTask = nil
            toastTask?.cancel()
            toastTask = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.deviceDidShakeNotification)) { _ in
            shakeToShuffle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openNowPlaying)) { _ in
            guard player.currentTrack != nil else { return }
            route = .player
        }
        .overlay(alignment: .top) {
            if let toast {
                Text(toast)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background {
                        Capsule().fill(Color.black.opacity(0.55))
                    }
                    .overlay {
                        Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                    }
                    .padding(.top, 54)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .allowsHitTesting(false)
            }
        }
        .task {
            // `configure` идемпотентен: повторный вход на экран не перетрёт
            // текущую очередь восстановленным состоянием.
            player.configure(userID: account.uid)
            waveSession.attach(player: player)
            await likes.load()
        }
    }

    @ViewBuilder
    private func destination(for route: MainRoute, onClose: @escaping () -> Void) -> some View {
        switch route {
        case .player:
            NowPlayingView(onOpenArtist: { artistID in
                openArtist(artistID)
            })
        case .liked:
            LikedTracksView(userID: account.uid)
        case .playlist(let playlist):
            PlaylistDetailView(
                playlist: playlist,
                userID: account.uid,
                onOpenArtist: { artistID in
                    openArtist(artistID)
                }
            )
        case .artist(let artistID):
            ArtistDetailView(artistID: artistID)
        case .album(let albumID):
            AlbumDetailView(albumID: albumID)
        case .search:
            SearchView(userID: account.uid)
        case .stats:
            StatsView()
        case .settings:
            SettingsView(account: account, onClose: onClose)
        }
    }

    /// Закрываем полноэкранный плеер и открываем артиста отдельным sheet.
    ///
    /// 250 мс — длительность стандартной анимации dismiss на iOS. Пауза
    /// нужна потому, что два `.sheet(item:)` подряд без неё на iOS 15
    /// теряют второй переход. Задача отменяется в `.onDisappear`.
    // MARK: - Тряска

    /// Shake to shuffle: играем случайный порядок лайкнутых треков.
    /// Если лайков нет — короткая плашка вместо пустого действия.
    private func shakeToShuffle() {
        Haptics.light()

        let likedIDs = Array(likes.likedIDs.prefix(100))
        guard !likedIDs.isEmpty else {
            showToast("Нет лайков для шаффла")
            return
        }

        Task { @MainActor in
            do {
                let tracks = try await APIManager.shared.tracks(ids: likedIDs)
                guard !tracks.isEmpty else {
                    showToast("Нет лайков для шаффла")
                    return
                }
                player.play(tracks: tracks.shuffled(), startAt: 0)
            } catch {
                logger.error("Шаффл лайков: \(error.localizedDescription, privacy: .public)")
                showToast("Не удалось загрузить лайки")
            }
        }
    }

    private func showToast(_ text: String) {
        toastTask?.cancel()

        withAnimation(.easeInOut(duration: 0.2)) {
            toast = text
        }

        toastTask = Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                toast = nil
            }
        }
    }

    private func openArtist(_ artistID: Int) {
        pendingRouteTask?.cancel()
        route = nil

        pendingRouteTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            route = .artist(artistID)
        }
    }

    // MARK: - Фон

    private var backgroundImageURL: URL? {
        player.currentTrack?.artworkURL ?? catalog.heroArtwork?.url
    }

    private var backgroundKey: String {
        player.currentTrack?.artworkURL?.absoluteString
            ?? catalog.heroArtwork?.key
            ?? "account-\(account.uid)"
    }
}

/// Куда открывается модальный экран. Один `.sheet(item:)` вместо нескольких
/// `.sheet`: несколько модальных модификаторов на одном view в SwiftUI
/// конфликтуют между собой.
enum MainRoute: Identifiable {
    case player
    case liked
    case playlist(Playlist)
    case artist(Int)
    case album(Int)
    case search
    case stats
    case settings

    var id: String {
        switch self {
        case .player: return "player"
        case .liked: return "liked"
        case .playlist(let playlist): return "playlist-\(playlist.id)"
        case .artist(let artistID): return "artist-\(artistID)"
        case .album(let albumID): return "album-\(albumID)"
        case .search: return "search"
        case .stats: return "stats"
        case .settings: return "settings"
        }
    }
}

// MARK: - Контент

/// Только раскладка. В теле нет ни одного чтения published-состояния:
/// каждая секция сама подписывается на то, что ей нужно. Поэтому смена
/// трека, тик прогресса или догрузка каталога не перерисовывают весь скролл.
private struct MainScrollContent: View {
    let account: Account
    let player: AudioPlayer
    let catalog: CatalogViewModel
    let wave: WaveViewModel
    @Binding var route: MainRoute?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                MainHeaderSection(account: account, catalog: catalog, route: $route)

                MainContinueSection(player: player)

                MainWaveSection(wave: wave, player: player)

                MainRecentsSection(player: player)

                CatalogView(
                    viewModel: catalog,
                    player: player,
                    onOpenLiked: { route = .liked },
                    onOpenPlaylist: { route = .playlist($0) }
                )

                MainFooterSection(route: $route)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 140)
        }
        .refreshable { await refreshAll() }
        .task {
            await catalog.loadIfNeeded()
            await wave.loadIfNeeded()
        }
    }

    /// Каталог и «Моя волна» обновляются параллельно: последовательный
    /// вариант держал бы индикатор в два раза дольше.
    private func refreshAll() async {
        async let feed: Void = catalog.refresh()
        async let waveRefresh: Void = wave.retry()
        _ = await (feed, waveRefresh)
    }
}

/// Мини-плеер: единственное место `MainView`, подписанное на сам плеер.
private struct MiniPlayerHost: View {
    let player: AudioPlayer
    var onOpen: () -> Void

    var body: some View {
        Group {
            if player.currentTrack != nil {
                MiniPlayerView(onOpen: onOpen)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: player.currentTrack?.id)
    }
}

// MARK: - Шапка

private struct MainHeaderSection: View {
    let account: Account
    @ObservedObject var catalog: CatalogViewModel
    @Binding var route: MainRoute?

    @EnvironmentObject private var stats: ListeningStatsStore
    @Environment(\.contentTone) private var tone

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if catalog.isRefreshing {
                HStack(spacing: 8) {
                    ProgressView()
                        .tint(tone.secondary)

                    Text("Обновляем...")
                        .font(.caption)
                        .foregroundStyle(tone.secondary)

                    Spacer(minLength: 0)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: catalog.isRefreshing)
    }

    /// Стрик: маленький чип у имени, тап открывает статистику.
    private var streakChip: some View {
        Button {
            Haptics.selection()
            route = .stats
        } label: {
            Text("🔥 \(stats.snapshot.currentStreak)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(tone.primary)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background { Capsule().fill(Color.white.opacity(0.1)) }
                .overlay {
                    Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                }
        }
        .buttonStyle(PressableStyle(scale: 0.94))
        .accessibilityLabel("Стрик \(stats.snapshot.currentStreak) дней. Открыть статистику")
    }

    private var header: some View {
        HStack(spacing: 14) {
            avatar

            VStack(alignment: .leading, spacing: 3) {
                Text("С возвращением")
                    .font(.caption)
                    .foregroundStyle(tone.tertiary)

                HStack(spacing: 8) {
                    Text(account.title)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(tone.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                    if stats.snapshot.currentStreak > 0 {
                        streakChip
                    }
                }

                HStack(spacing: 5) {
                    if let login = account.login, !login.isEmpty {
                        Text("@\(login)")
                            .lineLimit(1)

                        Text("·")
                            .foregroundStyle(tone.tertiary)
                    }

                    Text(AppInfo.versionText)
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(tone.secondary)
            }

            Spacer(minLength: 8)

            GlassIconButton("magnifyingglass", label: "Поиск") {
                route = .search
            }

            GlassIconButton("gearshape", label: "Настройки") {
                route = .settings
            }

            if account.hasPlus {
                Text("PLUS")
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(0.8)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(
                        Capsule().fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.99, green: 0.62, blue: 0.18),
                                    Color(red: 0.92, green: 0.32, blue: 0.10)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    )
                    .accessibilityLabel("Подписка Plus активна")
            }
        }
    }

    private var avatar: some View {
        Text(initial)
            .font(.system(size: 22, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 56, height: 56)
            .background {
                Circle().fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.99, green: 0.45, blue: 0.12),
                            Color(red: 0.86, green: 0.10, blue: 0.24)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            }
            .overlay { Circle().strokeBorder(Color.white.opacity(0.28), lineWidth: 1) }
            .shadow(color: .black.opacity(0.3), radius: 12, x: 0, y: 6)
            .accessibilityHidden(true)
    }

    private var initial: String {
        let source = account.displayName ?? account.fullName ?? account.login ?? "Y"
        let first = source.first.map(String.init) ?? "Y"
        return first.uppercased()
    }
}

// MARK: - Продолжить слушать

private struct MainContinueSection: View {
    @ObservedObject var player: AudioPlayer

    @Environment(\.contentTone) private var tone

    var body: some View {
        Group {
            if let track = player.currentTrack, showsCard {
                card(track)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: showsCard)
    }

    /// Пауза — единственный случай, когда карточка нужна: при `.playing`
    /// трек уже виден в MiniPlayer, при `.idle`/`.failed`/пустой очереди
    /// продолжать нечего. `.preparing` тоже не показываем — иначе карточка
    /// мигает на каждом переключении.
    private var showsCard: Bool {
        guard player.currentTrack != nil, !player.queue.isEmpty else { return false }
        if case .paused = player.status { return true }
        return false
    }

    private func card(_ track: Track) -> some View {
        GlassCard(cornerRadius: 20, padding: 12) {
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

                    Text(track.artistLine)
                        .font(.caption2)
                        .foregroundStyle(tone.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                // Иконка, а не Button: тап по всей карточке уже вызывает
                // togglePlayPause, вложенная кнопка дала бы двойной вызов.
                Image(systemName: "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tone.primary)
                    .frame(width: 38, height: 38)
                    .background {
                        Circle()
                            .fill(.ultraThinMaterial)
                            .overlay { Circle().fill(Color.black.opacity(0.14)) }
                    }
                    .overlay {
                        Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                    }
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .onTapGesture {
            Haptics.light()
            player.togglePlayPause()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Продолжить: \(track.title)")
        .accessibilityHint("Играть")
        .accessibilityAction {
            Haptics.light()
            player.togglePlayPause()
        }
    }
}

// MARK: - Моя волна

private struct MainWaveSection: View {
    @ObservedObject var wave: WaveViewModel
    let player: AudioPlayer

    @EnvironmentObject private var waveSession: WaveSessionController
    @ObservedObject private var highlight = PlaybackHighlight.shared
    @Environment(\.contentTone) private var tone

    var body: some View {
        Group {
            switch wave.state {
            case .idle, .loading:
                placeholder(isLoading: true)

            case .loaded(let tracks):
                loaded(tracks)

            case .failed(let error):
                failCard(error)
            }
        }
    }

    /// Витрина: до загрузки и при ошибке карточка остаётся «Моей волной»,
    /// но без выдуманных треков.
    private func placeholder(isLoading: Bool) -> some View {
        GlassCard(cornerRadius: 30, padding: 20) {
            VStack(alignment: .leading, spacing: 16) {
                titleRow

                VStack(alignment: .leading, spacing: 8) {
                    Text("Поток под ваше настроение")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(tone.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    if isLoading {
                        HStack(spacing: 8) {
                            ProgressView().tint(tone.secondary)
                            Text("Готовим подборку...")
                                .font(.footnote)
                                .foregroundStyle(tone.secondary)
                        }
                    }
                }

                HStack(spacing: 8) {
                    GlassChip("Энергичное")
                    GlassChip("Спокойное")
                    GlassChip("В дорогу")
                }
            }
        }
    }

    private var titleRow: some View {
        HStack(spacing: 10) {
            GlassChip("Моя волна", systemImage: "waveform")

            Spacer(minLength: 0)

            Image(systemName: "sparkles")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tone.tertiary)
        }
    }

    private func loaded(_ tracks: [Track]) -> some View {
        GlassCard(cornerRadius: 30, padding: 20) {
            VStack(alignment: .leading, spacing: 16) {
                titleRow

                Text("Поток под ваше настроение")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(tone.primary)
                    .fixedSize(horizontal: false, vertical: true)

                chips

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(tracks) { track in
                            Button {
                                Haptics.light()
                                waveSession.start(from: track)
                            } label: {
                                WaveTrackCardView(
                                    track: track,
                                    isCurrent: highlight.trackID == track.id,
                                    isPlaying: highlight.isPlaying
                                )
                            }
                            .buttonStyle(PressableStyle(scale: 0.96))
                        }
                    }
                    .padding(.vertical, 2)
                }

                playWaveButton

                if let failure = waveSession.failure {
                    ErrorStateCard(error: failure, cornerRadius: 24, padding: 16) {
                        waveSession.start()
                    }
                }
            }
        }
    }

    /// Чипы настроек волны. Значения превращаются в сиды сессии
    /// (`settingDiversity:discover`, `settingLanguage:russian`,
    /// `mood:calm`, `mood:energetic`); «спокойное» и «энергичное» —
    /// взаимоисключающие, потому что сервер принимает один `mood`.
    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("Только новое", isOn: waveSession.settings.onlyNew) {
                    updateSettings { $0.onlyNew.toggle() }
                }

                chip("По-русски", isOn: waveSession.settings.russian) {
                    updateSettings { $0.russian.toggle() }
                }

                chip("Спокойное", isOn: waveSession.settings.mood == .calm) {
                    updateSettings { settings in
                        settings.mood = settings.mood == .calm ? nil : .calm
                    }
                }

                chip("Энергичное", isOn: waveSession.settings.mood == .energetic) {
                    updateSettings { settings in
                        settings.mood = settings.mood == .energetic ? nil : .energetic
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func chip(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isOn ? tone.primary : tone.secondary)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background {
                    Capsule()
                        .fill(isOn ? Color.white.opacity(0.18) : Color.white.opacity(0.06))
                }
                .overlay {
                    Capsule()
                        .strokeBorder(
                            isOn ? Color.white.opacity(0.35) : Color.white.opacity(0.12),
                            lineWidth: 1
                        )
                }
        }
        .buttonStyle(PressableStyle(scale: 0.95))
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityLabel(title)
        .accessibilityHint(isOn ? "Выключить" : "Включить")
    }

    private func updateSettings(_ change: (inout WaveSettings) -> Void) {
        var settings = waveSession.settings
        change(&settings)
        waveSession.settings = settings
    }

    @ViewBuilder
    private var playWaveButton: some View {
        if waveSession.isStarting {
            HStack(spacing: 8) {
                ProgressView().tint(tone.secondary)
                Text("Запускаем волну...")
                    .font(.footnote)
                    .foregroundStyle(tone.secondary)
                Spacer(minLength: 0)
            }
            .frame(height: 46)
        } else {
            GlassButton(
                "Играть всё",
                systemImage: "play.fill",
                prominence: .prominent,
                fullWidth: true
            ) {
                Haptics.light()
                waveSession.start()
            }
        }
    }

    private func failCard(_ error: APIError) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            titleRow
                .padding(.horizontal, 4)

            ErrorStateCard(error: error, cornerRadius: 30) {
                Task { await wave.retry() }
            }
        }
    }
}

/// Карточка трека волны. Отдельная структура, чтобы подсветка текущего
/// трека не заставляла перерисовываться всю карточку «Моей волны».
private struct WaveTrackCardView: View {
    let track: Track
    let isCurrent: Bool
    let isPlaying: Bool

    @Environment(\.contentTone) private var tone

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                CachedAsyncImage(url: track.artworkURL) {
                    ZStack {
                        Color.white.opacity(0.07)
                        Image(systemName: "music.note")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(.white.opacity(0.25))
                    }
                }
                .frame(width: 92, height: 92)

                if isCurrent {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.black.opacity(0.45))

                    Image(systemName: isPlaying ? "waveform" : "pause.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 92, height: 92)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            }

            Text(track.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tone.primary)
                .lineLimit(2)
                .frame(width: 92, alignment: .leading)
                .frame(minHeight: 30, alignment: .topLeading)
        }
    }
}

// MARK: - Недавнее

private struct MainRecentsSection: View {
    let player: AudioPlayer

    /// Лента хранится в локальном состоянии: подписка на `$recents`
    /// обновляет только эту секцию, а не весь скролл.
    @State private var recents: [Track] = []

    @Environment(\.contentTone) private var tone

    var body: some View {
        Group {
            if !tracks.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    GlassSectionHeader("Недавнее", subtitle: "Локально, последние треки")

                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(tracks) { track in
                                Button {
                                    Haptics.light()
                                    player.play(track: track, in: tracks)
                                } label: {
                                    card(track)
                                }
                                .buttonStyle(PressableStyle(scale: 0.96))
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .onAppear { recents = player.recents }
        .onReceive(player.$recents) { recents = $0 }
    }

    /// Последние треки из `PlaybackStateStore` (заполняется в `AudioPlayer`
    /// при каждом `play`). Показываем 10 — в хранилище лежит до 20.
    private var tracks: [Track] {
        var seen = Set<Int>()
        var result: [Track] = []

        for track in recents.prefix(10) {
            guard seen.insert(track.id).inserted else { continue }
            result.append(track)
        }

        return result
    }

    private func card(_ track: Track) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CachedAsyncImage(url: track.artworkURL) {
                ZStack {
                    Color.white.opacity(0.07)
                    Image(systemName: "music.note")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.white.opacity(0.25))
                }
            }
            .frame(width: 100, height: 100)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            }

            Text(track.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tone.primary)
                .lineLimit(2)
                .frame(width: 100, alignment: .leading)
                .frame(minHeight: 30, alignment: .topLeading)

            Text(track.artistLine)
                .font(.caption2)
                .foregroundStyle(tone.tertiary)
                .lineLimit(1)
                .frame(width: 100, alignment: .leading)
        }
        .frame(width: 100, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(track.title), \(track.artistLine)")
        .accessibilityHint("Играть")
    }
}

// MARK: - Подвал

private struct MainFooterSection: View {
    @Binding var route: MainRoute?

    @ObservedObject private var highlight = PlaybackHighlight.shared
    @Environment(\.contentTone) private var tone

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if highlight.trackID != nil {
                GlassButton(
                    "Открыть плеер",
                    systemImage: "play.circle",
                    fullWidth: true
                ) {
                    route = .player
                }
            }

            GlassButton(
                "Настройки",
                systemImage: "gearshape",
                fullWidth: true
            ) {
                route = .settings
            }

            Text("YMusic · неофициальный клиент")
                .font(.caption2)
                .foregroundStyle(tone.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.top, 6)
    }
}
