import SwiftUI

/// Главный экран: фон из обложки текущего трека (или первой обложки каталога),
/// шапка аккаунта, hero-карточка «Моя волна», секции каталога и мини-плеер.
///
/// `LikeStore` создаётся здесь: он привязан к `userID` аккаунта и доступен
/// всему поддереву (каталог, «Мне нравится», плейлист, поиск, плеер) через
/// environment.
struct MainView: View {
    let account: Account

    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var player: AudioPlayer

    @StateObject private var catalog: CatalogViewModel
    @StateObject private var likes: LikeStore
    @StateObject private var wave: WaveViewModel
    @State private var route: MainRoute?

    @MainActor
    init(account: Account) {
        self.account = account
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
                    catalog: catalog,
                    wave: wave,
                    route: $route
                )

                if player.currentTrack != nil {
                    MiniPlayerView {
                        route = .player
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .environmentObject(likes)
        .animation(.easeInOut(duration: 0.25), value: player.currentTrack?.id)
        .sheet(item: $route) { route in
            destination(for: route)
                .environmentObject(player)
                .environmentObject(likes)
                .preferredColorScheme(.dark)
        }
        .onAppear {
            catalog.onSessionExpired = {
                Task {
                    player.resetForSignOut()
                    await auth.signOut()
                }
            }
        }
        .task {
            // `configure` идемпотентен: повторный вход на экран не перетрёт
            // текущую очередь восстановленным состоянием.
            player.configure(userID: account.uid)
            await likes.load()
        }
    }

    @ViewBuilder
    private func destination(for route: MainRoute) -> some View {
        switch route {
        case .player:
            NowPlayingView()
        case .liked:
            LikedTracksView(userID: account.uid)
        case .playlist(let playlist):
            PlaylistDetailView(playlist: playlist, userID: account.uid)
        case .search:
            SearchView(userID: account.uid)
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
    case search

    var id: String {
        switch self {
        case .player: return "player"
        case .liked: return "liked"
        case .playlist(let playlist): return "playlist-\(playlist.id)"
        case .search: return "search"
        }
    }
}

// MARK: - Контент

private struct MainScrollContent: View {
    let account: Account
    @ObservedObject var catalog: CatalogViewModel
    @ObservedObject var wave: WaveViewModel
    @Binding var route: MainRoute?

    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var player: AudioPlayer
    @Environment(\.contentTone) private var tone

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 26) {
                header
                waveCard

                if catalog.isLoadingInitial, !player.recents.isEmpty {
                    recentsSection
                }

                CatalogView(
                    viewModel: catalog,
                    onOpenLiked: { route = .liked },
                    onOpenPlaylist: { route = .playlist($0) }
                )

                footer
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 140)
        }
        .refreshable { await catalog.refresh() }
        .task {
            await catalog.loadIfNeeded()
            await wave.loadIfNeeded()
        }
    }

    // MARK: Шапка

    private var header: some View {
        HStack(spacing: 14) {
            avatar

            VStack(alignment: .leading, spacing: 3) {
                Text("С возвращением")
                    .font(.caption)
                    .foregroundStyle(tone.tertiary)

                Text(account.title)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(tone.primary)
                    .lineLimit(1)

                if let login = account.login, !login.isEmpty {
                    Text("@\(login)")
                        .font(.caption)
                        .foregroundStyle(tone.secondary)
                }
            }

            Spacer(minLength: 8)

            GlassIconButton("magnifyingglass", label: "Поиск") {
                route = .search
            }

            if catalog.isRefreshing {
                ProgressView()
                    .tint(tone.secondary)
                    .frame(width: 40, height: 40)
            } else {
                GlassIconButton("arrow.clockwise", label: "Обновить") {
                    Task { await catalog.refresh() }
                }
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

    // MARK: Моя волна

    @ViewBuilder
    private var waveCard: some View {
        switch wave.state {
        case .idle, .loading:
            wavePlaceholder(isLoading: true)

        case .loaded(let tracks):
            waveLoaded(tracks)

        case .failed(let error):
            waveFailCard(error)
        }
    }

    /// Витрина: до загрузки и при ошибке карточка остаётся «Моей волной»,
    /// но без выдуманных треков.
    private func wavePlaceholder(isLoading: Bool) -> some View {
        GlassCard(cornerRadius: 30, padding: 20) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    GlassChip("Моя волна", systemImage: "waveform")

                    Spacer(minLength: 0)

                    Image(systemName: "sparkles")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(tone.tertiary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Поток под ваше настроение")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(tone.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    if isLoading {
                        HStack(spacing: 8) {
                            ProgressView().tint(tone.secondary)
                            Text("Готовим подборку…")
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

    private func waveLoaded(_ tracks: [Track]) -> some View {
        GlassCard(cornerRadius: 30, padding: 20) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    GlassChip("Моя волна", systemImage: "waveform")

                    Spacer(minLength: 0)

                    Image(systemName: "sparkles")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(tone.tertiary)
                }

                Text("Поток под ваше настроение")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(tone.primary)
                    .fixedSize(horizontal: false, vertical: true)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(tracks) { track in
                            Button {
                                player.play(track: track, in: tracks)
                            } label: {
                                waveTrackCard(track)
                            }
                            .buttonStyle(PressableStyle(scale: 0.96))
                        }
                    }
                    .padding(.vertical, 2)
                }

                GlassButton(
                    "Играть всё",
                    systemImage: "play.fill",
                    prominence: .prominent,
                    fullWidth: true
                ) {
                    player.play(tracks: tracks, startAt: 0)
                }
            }
        }
    }

    private func waveTrackCard(_ track: Track) -> some View {
        let isCurrent = player.currentTrack?.id == track.id

        return VStack(alignment: .leading, spacing: 8) {
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

                    Image(systemName: player.isPlaying ? "waveform" : "pause.fill")
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

    private func waveFailCard(_ error: APIError) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                GlassChip("Моя волна", systemImage: "waveform")

                Spacer(minLength: 0)

                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tone.tertiary)
            }
            .padding(.horizontal, 4)

            ErrorStateCard(error: error, cornerRadius: 30) {
                Task { await wave.retry() }
            }
        }
    }

    // MARK: Недавнее

    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            GlassSectionHeader("Недавнее", subtitle: "Локально, до загрузки каталога")

            GlassCard(cornerRadius: 24, padding: 8) {
                VStack(spacing: 0) {
                    ForEach(Array(player.recents.enumerated()), id: \.element.id) { index, track in
                        recentsRow(track)

                        if index < player.recents.count - 1 {
                            Rectangle()
                                .fill(Color.white.opacity(0.07))
                                .frame(height: 0.5)
                                .padding(.leading, 68)
                        }
                    }
                }
            }
        }
    }

    private func recentsRow(_ track: Track) -> some View {
        let isCurrent = player.currentTrack?.id == track.id
        let queue = player.recents

        return TrackRowView(
            track: track,
            isCurrent: isCurrent,
            isPlaying: isCurrent && player.isPlaying,
            onTap: { player.play(track: track, in: queue) }
        )
    }

    // MARK: Подвал

    private var footer: some View {
        VStack(alignment: .leading, spacing: 14) {
            if player.currentTrack != nil {
                GlassButton(
                    "Открыть плеер",
                    systemImage: "play.circle",
                    fullWidth: true
                ) {
                    route = .player
                }
            }

            GlassButton(
                "Выйти из аккаунта",
                systemImage: "rectangle.portrait.and.arrow.right",
                fullWidth: true
            ) {
                Task {
                    player.resetForSignOut()
                    await auth.signOut()
                }
            }

            Text("Фаза 6 · поиск и «Моя волна»")
                .font(.caption2)
                .foregroundStyle(tone.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.top, 6)
    }
}
