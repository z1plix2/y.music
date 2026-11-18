import SwiftUI

/// Секции каталога. Без собственного `ScrollView`: живёт внутри
/// `MainScrollContent`, чтобы pull-to-refresh и шапка оставались общими.
///
/// Открытие библиотеки/плейлиста вынесено наружу замыканиями: `CatalogView`
/// не знает, как показывать экраны (sheet или push) — это решает `MainView`.
struct CatalogView: View {
    @ObservedObject var viewModel: CatalogViewModel
    /// Значение, а не `@EnvironmentObject`: иначе каждый тик прогресса
    /// перерисовывал бы все секции каталога.
    var player: AudioPlayer

    var onOpenLiked: () -> Void = {}
    var onOpenPlaylist: (Playlist) -> Void = { _ in }

    @Environment(\.contentTone) private var tone

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Group {
                switch viewModel.state {
                case .idle, .loading:
                    skeletonSections

                case .loaded(let landings):
                    if landings.isEmpty {
                        emptyCard
                    } else {
                        ForEach(landings) { landing in
                            switch landing.kind {
                            case .playlists:
                                playlistSection(landing)
                            case .likedTracks:
                                trackSection(landing)
                            }
                        }
                    }

                case .failed(let error):
                    errorCard(error)
                }
            }
            .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.25), value: stateKey)
    }

    /// Смена скелетон → контент/ошибка анимируется только по этой «фазе»:
    /// догрузка страниц не должна перезапускать fade.
    private var stateKey: Int {
        switch viewModel.state {
        case .idle: return 0
        case .loading: return 1
        case .loaded: return 2
        case .failed: return 3
        }
    }

    // MARK: - Секции

    private func playlistSection(_ landing: Landing) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            GlassSectionHeader(landing.title, subtitle: landing.subtitle)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(landing.items) { item in
                        if case .playlist(let playlist) = item {
                            Button {
                                onOpenPlaylist(playlist)
                            } label: {
                                PlaylistCardView(playlist: playlist)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func trackSection(_ landing: Landing) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            GlassSectionHeader(
                landing.title,
                subtitle: landing.subtitle,
                trailingTitle: "Все",
                trailingAction: onOpenLiked
            )

            GlassCard(cornerRadius: 24, padding: 8) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(landing.items.enumerated()), id: \.element.id) { index, item in
                        if case .track(let track) = item {
                            trackRow(track)

                            if index < landing.items.count - 1 {
                                Rectangle()
                                    .fill(Color.white.opacity(0.07))
                                    .frame(height: 0.5)
                                    .padding(.leading, 68)
                            }
                        }
                    }

                    if viewModel.isLoadingMoreLiked {
                        ProgressView()
                            .tint(tone.secondary)
                            .padding(.vertical, 12)
                    }
                }
            }
        }
    }

    private func trackRow(_ track: Track) -> some View {
        CatalogTrackRow(
            track: track,
            queue: viewModel.likedTracks,
            player: player,
            onAppearLoadMore: {
                Task { await viewModel.loadMoreLikedIfNeeded(currentItemID: "t-\(track.id)") }
            }
        )
    }

    // MARK: - Состояния

    private var skeletonSections: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 14) {
                bar(width: 140, height: 14)

                HStack(spacing: 14) {
                    ForEach(0..<3, id: \.self) { _ in
                        SkeletonCard()
                    }
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                bar(width: 180, height: 14)

                GlassCard(cornerRadius: 24, padding: 8) {
                    VStack(spacing: 0) {
                        ForEach(0..<4, id: \.self) { _ in
                            SkeletonRow()
                        }
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func errorCard(_ error: APIError) -> some View {
        ErrorStateCard(error: error) {
            Task { await viewModel.retry() }
        }
    }

    private var emptyCard: some View {
        EmptyStateCard(
            systemImage: "music.note.list",
            title: "Здесь пока пусто",
            message: "Плейлисты и лайки появятся, как только в аккаунте что-то будет. Если они точно есть — потяните экран вниз.",
            actionTitle: "Обновить",
            action: { Task { await viewModel.retry() } }
        )
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(Color.white.opacity(0.12))
            .frame(width: width, height: height)
    }
}

/// Строка каталога со своей подпиской на подсветку. Раньше `isCurrent`
/// считался в `CatalogView`, и один тик плеера перерисовывал весь список.
private struct CatalogTrackRow: View {
    let track: Track
    let queue: [Track]
    let player: AudioPlayer
    let onAppearLoadMore: () -> Void

    @ObservedObject private var highlight = PlaybackHighlight.shared

    var body: some View {
        let isCurrent = highlight.trackID == track.id

        TrackRowView(
            track: track,
            isCurrent: isCurrent,
            isPlaying: isCurrent && highlight.isPlaying,
            onTap: { player.play(track: track, in: queue) }
        )
        .onAppear(perform: onAppearLoadMore)
    }
}

// MARK: - Карточка плейлиста

private struct PlaylistCardView: View {
    let playlist: Playlist

    @Environment(\.contentTone) private var tone

    private let side: CGFloat = 148

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CachedAsyncImage(url: playlist.artworkURL) {
                placeholder
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.3), radius: 12, x: 0, y: 6)

            Text(playlist.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tone.primary)
                .lineLimit(2)
                .frame(width: side, alignment: .leading)
                .frame(minHeight: 36, alignment: .topLeading)

            Text(playlist.subtitle)
                .font(.caption2)
                .foregroundStyle(tone.tertiary)
                .lineLimit(1)
        }
    }

    private var placeholder: some View {
        ZStack {
            Color.white.opacity(0.07)
            ProgressView()
                .tint(.white.opacity(0.5))
        }
    }
}

// MARK: - Скелетоны

private struct SkeletonCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.07))
                .frame(width: 148, height: 148)

            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.white.opacity(0.12))
                .frame(width: 110, height: 10)

            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.white.opacity(0.07))
                .frame(width: 70, height: 8)
        }
    }
}

private struct SkeletonRow: View {
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
