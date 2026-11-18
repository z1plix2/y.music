import SwiftUI

/// Секции каталога. Без собственного `ScrollView`: живёт внутри
/// `MainScrollContent`, чтобы pull-to-refresh и шапка оставались общими.
///
/// Открытие библиотеки/плейлиста вынесено наружу замыканиями: `CatalogView`
/// не знает, как показывать экраны (sheet или push) — это решает `MainView`.
struct CatalogView: View {
    @ObservedObject var viewModel: CatalogViewModel

    var onOpenLiked: () -> Void = {}
    var onOpenPlaylist: (Playlist) -> Void = { _ in }

    @EnvironmentObject private var player: AudioPlayer
    @Environment(\.contentTone) private var tone

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
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
                VStack(spacing: 0) {
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
        let isCurrent = player.currentTrack?.id == track.id
        let queue = viewModel.likedTracks

        return TrackRowView(
            track: track,
            isCurrent: isCurrent,
            isPlaying: isCurrent && player.isPlaying,
            onTap: { player.play(track: track, in: queue) }
        )
        .onAppear {
            Task { await viewModel.loadMoreLikedIfNeeded(currentItemID: "t-\(track.id)") }
        }
    }

    // MARK: - Состояния

    private var skeletonSections: some View {
        VStack(alignment: .leading, spacing: 26) {
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
        GlassCard(cornerRadius: 24, padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: error.requiresReauthentication ? "lock.slash" : "exclamationmark.triangle")
                        .font(.system(size: 16, weight: .semibold))

                    Text(error.requiresReauthentication ? "Сессия истекла" : "Не удалось загрузить")
                        .font(.system(size: 16, weight: .semibold))
                }
                .foregroundStyle(tone.primary)

                Text(error.localizedDescription)
                    .font(.footnote)
                    .foregroundStyle(tone.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                GlassButton(
                    error.requiresReauthentication ? "Войти заново" : "Повторить",
                    systemImage: error.requiresReauthentication ? "person.crop.circle" : "arrow.clockwise"
                ) {
                    Task { await viewModel.retry() }
                }
            }
        }
    }

    private var emptyCard: some View {
        GlassCard(cornerRadius: 24, padding: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Здесь пока пусто")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tone.primary)

                Text("Плейлисты и лайки появятся, как только в аккаунте что-то будет.")
                    .font(.footnote)
                    .foregroundStyle(tone.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(Color.white.opacity(0.12))
            .frame(width: width, height: height)
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
