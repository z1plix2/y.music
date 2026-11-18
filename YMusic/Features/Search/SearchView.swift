import SwiftUI

/// Поиск. Открывается модальным экраном из шапки главного, а не через
/// `NavigationView`: `.searchable` на iOS 15 привязан к навигации и не даёт
/// стеклянного поля в стиле остального приложения, поэтому search-bar свой.
struct SearchView: View {
    @StateObject private var viewModel: SearchViewModel

    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var likes: LikeStore
    @Environment(\.contentTone) private var tone
    @Environment(\.dismiss) private var dismiss

    @FocusState private var isFieldFocused: Bool
    @State private var route: SearchRoute?

    init(userID: Int) {
        _viewModel = StateObject(wrappedValue: SearchViewModel(userID: userID))
    }

    var body: some View {
        DynamicBackground(
            imageURL: viewModel.results?.tracks.first?.artworkURL,
            cacheKey: viewModel.results?.tracks.first?.artworkURL?.absoluteString ?? "search",
            fallback: .brand
        ) {
            VStack(spacing: 0) {
                topBar
                searchBar

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 22) {
                        content
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 40)
                    .animation(.easeInOut(duration: 0.25), value: contentKey)
                }
            }
        }
        .onAppear {
            viewModel.loadHistory()
            isFieldFocused = true
        }
        .onChange(of: viewModel.query) { _ in
            viewModel.queryChanged()
        }
        .onDisappear {
            viewModel.cancel()
        }
        .sheet(item: $route) { route in
            destination(for: route)
                .environmentObject(player)
                .environmentObject(likes)
                .preferredColorScheme(.dark)
        }
    }

    /// Один `.sheet(item:)` на экран: три отдельных модификатора на одном
    /// view в SwiftUI конфликтуют между собой.
    @ViewBuilder
    private func destination(for route: SearchRoute) -> some View {
        switch route {
        case .playlist(let playlist):
            PlaylistDetailView(playlist: playlist, userID: viewModel.userID)
        case .artist(let artistID):
            ArtistDetailView(artistID: artistID)
        case .album(let albumID):
            AlbumDetailView(albumID: albumID)
        }
    }

    // MARK: - Панель и поле

    private var topBar: some View {
        HStack {
            GlassIconButton("chevron.down", label: "Закрыть") {
                dismiss()
            }

            Spacer()

            Text("Поиск")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(tone.primary)

            Spacer()

            Color.clear.frame(width: 40, height: 40)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tone.tertiary)

            TextField("Треки, артисты, альбомы", text: $viewModel.query)
                .textFieldStyle(.plain)
                .foregroundStyle(tone.primary)
                .focused($isFieldFocused)
                .submitLabel(.search)
                .onSubmit { viewModel.submit(viewModel.query) }

            if !viewModel.query.isEmpty {
                Button {
                    viewModel.clearQuery()
                    isFieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(tone.tertiary)
                }
                .buttonStyle(PressableStyle(scale: 0.9))
                .accessibilityLabel("Очистить")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
        .glassPanel(cornerRadius: 23)
        .padding(.horizontal, 20)
        .padding(.top, 6)
    }

    // MARK: - Контент

    @ViewBuilder
    private var content: some View {
        Group {
            if viewModel.isShowingHistory {
                historySection
            } else {
                switch viewModel.state {
                case .idle, .loading:
                    skeleton

                case .loaded(let result):
                    if result.isEmpty {
                        emptyCard
                    } else {
                        resultSections(result)
                    }

                case .failed(let error):
                    errorCard(error)
                }
            }
        }
        .transition(.opacity)
    }

    /// Стабильный ключ фазы: fade только при скелетон → результат/ошибка,
    /// а не на каждый новый результат ввода.
    private var contentKey: String {
        if viewModel.isShowingHistory { return "history" }
        switch viewModel.state {
        case .idle: return "idle"
        case .loading: return "loading"
        case .loaded: return "loaded"
        case .failed: return "failed"
        }
    }

    // MARK: - История

    @ViewBuilder
    private var historySection: some View {
        if viewModel.history.isEmpty {
            GlassCard(cornerRadius: 24, padding: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Начните вводить запрос")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(tone.primary)

                    Text("Найдём треки, артистов, альбомы и плейлисты.")
                        .font(.footnote)
                        .foregroundStyle(tone.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 14) {
                GlassSectionHeader(
                    "Недавние запросы",
                    trailingTitle: "Очистить",
                    trailingAction: { viewModel.clearHistory() }
                )

                GlassCard(cornerRadius: 24, padding: 8) {
                    VStack(spacing: 0) {
                        ForEach(Array(viewModel.history.enumerated()), id: \.offset) { index, item in
                            historyRow(item)

                            if index < viewModel.history.count - 1 {
                                Rectangle()
                                    .fill(Color.white.opacity(0.07))
                                    .frame(height: 0.5)
                                    .padding(.leading, 44)
                            }
                        }
                    }
                }
            }
        }
    }

    private func historyRow(_ item: String) -> some View {
        Button {
            viewModel.submit(item)
            isFieldFocused = false
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tone.tertiary)
                    .frame(width: 24)

                Text(item)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(tone.primary)
                    .lineLimit(1)

                Spacer(minLength: 4)
            }
            .padding(.horizontal, 8)
            .frame(height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.99))
    }

    // MARK: - Результаты

    @ViewBuilder
    private func resultSections(_ result: SearchResult) -> some View {
        if !result.tracks.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                GlassSectionHeader("Треки", subtitle: "\(result.tracks.count)")

                GlassCard(cornerRadius: 24, padding: 8) {
                    VStack(spacing: 0) {
                        ForEach(Array(result.tracks.enumerated()), id: \.element.id) { index, track in
                            trackRow(track, in: result.tracks)

                            if index < result.tracks.count - 1 {
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

        if !result.artists.isEmpty {
            cardStrip(title: "Артисты") {
                ForEach(result.artists) { artist in
                    if artist.id > 0 {
                        Button {
                            Haptics.selection()
                            route = .artist(artist.id)
                        } label: {
                            SearchArtistCard(artist: artist)
                        }
                        .buttonStyle(PressableStyle(scale: 0.97))
                    } else {
                        SearchArtistCard(artist: artist)
                    }
                }
            }
        }

        if !result.albums.isEmpty {
            cardStrip(title: "Альбомы") {
                ForEach(result.albums) { album in
                    Button {
                        Haptics.selection()
                        route = .album(album.id)
                    } label: {
                        SearchAlbumCard(album: album)
                    }
                    .buttonStyle(PressableStyle(scale: 0.97))
                }
            }
        }

        if !result.playlists.isEmpty {
            cardStrip(title: "Плейлисты") {
                ForEach(result.playlists) { playlist in
                    Button {
                        route = .playlist(playlist)
                    } label: {
                        SearchPlaylistCard(playlist: playlist)
                    }
                    .buttonStyle(PressableStyle(scale: 0.97))
                }
            }
        }
    }

    private func trackRow(_ track: Track, in tracks: [Track]) -> some View {
        let isCurrent = player.currentTrack?.id == track.id

        return TrackRowView(
            track: track,
            isCurrent: isCurrent,
            isPlaying: isCurrent && player.isPlaying,
            onTap: { player.play(track: track, in: tracks) }
        )
    }

    private func cardStrip<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            GlassSectionHeader(title)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    content()
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Состояния

    private var skeleton: some View {
        GlassCard(cornerRadius: 24, padding: 8) {
            VStack(spacing: 0) {
                ForEach(0..<6, id: \.self) { _ in
                    SkeletonSearchRow()
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func errorCard(_ error: APIError) -> some View {
        ErrorStateCard(error: error, context: .search) {
            viewModel.retry()
        }
    }

    private var emptyCard: some View {
        GlassCard(cornerRadius: 24, padding: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Ничего не найдено")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tone.primary)

                Text("Попробуйте другой запрос: название, исполнителя или альбом.")
                    .font(.footnote)
                    .foregroundStyle(tone.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Маршрут поиска

/// Куда открывается карточка результата. Один enum — один `.sheet(item:)`:
/// несколько модальных модификаторов на одном view конфликтуют.
enum SearchRoute: Identifiable {
    case playlist(Playlist)
    case artist(Int)
    case album(Int)

    var id: String {
        switch self {
        case .playlist(let playlist): return "playlist-\(playlist.id)"
        case .artist(let artistID): return "artist-\(artistID)"
        case .album(let albumID): return "album-\(albumID)"
        }
    }
}

// MARK: - Карточки результатов

private struct SearchArtistCard: View {
    let artist: Artist

    @Environment(\.contentTone) private var tone

    var body: some View {
        VStack(spacing: 8) {
            CachedAsyncImage(url: artist.artworkURL) {
                ZStack {
                    Color.white.opacity(0.07)
                    Image(systemName: "person.fill")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white.opacity(0.25))
                }
            }
            .frame(width: 96, height: 96)
            .clipShape(Circle())
            .overlay { Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1) }

            Text(artist.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tone.primary)
                .lineLimit(2)
                .frame(width: 96, alignment: .center)
                .frame(minHeight: 32, alignment: .top)
        }
    }
}

private struct SearchAlbumCard: View {
    let album: Album

    @Environment(\.contentTone) private var tone

    private let side: CGFloat = 128

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CachedAsyncImage(url: album.artworkURL) {
                ZStack {
                    Color.white.opacity(0.07)
                    Image(systemName: "square.stack")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.white.opacity(0.25))
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            }

            Text(album.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tone.primary)
                .lineLimit(2)
                .frame(width: side, alignment: .leading)
                .frame(minHeight: 32, alignment: .topLeading)
        }
    }
}

private struct SearchPlaylistCard: View {
    let playlist: Playlist

    @Environment(\.contentTone) private var tone

    private let side: CGFloat = 128

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CachedAsyncImage(url: playlist.artworkURL) {
                ZStack {
                    Color.white.opacity(0.07)
                    Image(systemName: "music.note.list")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.white.opacity(0.25))
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            }

            Text(playlist.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tone.primary)
                .lineLimit(2)
                .frame(width: side, alignment: .leading)
                .frame(minHeight: 32, alignment: .topLeading)

            Text(playlist.subtitle)
                .font(.caption2)
                .foregroundStyle(tone.tertiary)
                .lineLimit(1)
        }
    }
}

/// Скелетон строки, совпадающий по геометрии с `TrackRowView`.
private struct SkeletonSearchRow: View {
    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(0.12))
                    .frame(height: 10)

                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(0.07))
                    .frame(width: 90, height: 8)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }
}
