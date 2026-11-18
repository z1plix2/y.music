import SwiftUI

/// Экран артиста: аватар, имя, общая статистика, популярные треки и
/// выборка альбомов.
///
/// Источник — `/artists/{id}/brief-info`. Секции подписаны нейтрально
/// («Популярные треки», «Альбомы»): сервер отдаёт до 10 треков и не всю
/// дискографию, поэтому число из `counts` не привязано к спискам.
struct ArtistDetailView: View {
    @StateObject private var viewModel: ArtistDetailViewModel
    @State private var openedAlbum: Album?

    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var likes: LikeStore
    @Environment(\.contentTone) private var tone
    @Environment(\.dismiss) private var dismiss

    init(artistID: Int) {
        _viewModel = StateObject(wrappedValue: ArtistDetailViewModel(artistID: artistID))
    }

    var body: some View {
        DynamicBackground(
            imageURL: viewModel.artist?.avatarURL,
            cacheKey: viewModel.artist?.avatarURL?.absoluteString ?? "artist-\(viewModel.artistID)",
            fallback: .brand
        ) {
            VStack(spacing: 0) {
                topBar

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 24) {
                        content
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
                    .padding(.bottom, 40)
                }
            }
        }
        .task { await viewModel.loadIfNeeded() }
        .sheet(item: $openedAlbum) { album in
            // TODO: на iOS 15 вложенный sheet может не открыться; если так —
            // заменить на callback с закрытием/переоткрытием.
            AlbumDetailView(albumID: album.id)
                .environmentObject(player)
                .environmentObject(likes)
        }
    }

    // MARK: - Панель

    private var topBar: some View {
        GlassScreenHeader(
            title: "Артист",
            subtitle: viewModel.artist?.name,
            onClose: { dismiss() }
        )
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    // MARK: - Контент

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .loading:
            headerSkeleton
            skeletonList

        case .loaded(let artist):
            header(artist)

            if artist.popularTracks.isEmpty && artist.albums.isEmpty {
                emptyCard
            } else {
                if !artist.popularTracks.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        GlassSectionHeader("Популярные треки")
                        trackList(artist.popularTracks)
                    }
                }

                if !artist.albums.isEmpty {
                    albumsSection(artist.albums)
                }
            }

        case .failed(let error):
            ErrorStateCard(error: error, context: .artist) {
                Task { await viewModel.retry() }
            }
        }
    }

    // MARK: - Шапка

    private func header(_ artist: ArtistDetail) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                avatar(artist.avatarURL)

                VStack(alignment: .leading, spacing: 8) {
                    Text(artist.name)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(tone.primary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)

                    if let stats = statsText(artist.counts) {
                        Text(stats)
                            .font(.caption)
                            .foregroundStyle(tone.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)
            }

            if !artist.popularTracks.isEmpty {
                GlassButton(
                    "Играть всё",
                    systemImage: "play.fill",
                    prominence: .prominent,
                    fullWidth: true
                ) {
                    play(artist.popularTracks, from: 0)
                }
            }
        }
    }

    private func avatar(_ url: URL?) -> some View {
        CachedAsyncImage(url: url) {
            ZStack {
                Color.white.opacity(0.07)
                Image(systemName: "person.fill")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.white.opacity(0.25))
            }
        }
        .frame(width: 120, height: 120)
        .clipShape(Circle())
        .overlay { Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1) }
        .shadow(color: .black.opacity(0.35), radius: 16, x: 0, y: 10)
    }

    /// Общая статистика артиста. Это не размеры показанных списков.
    private func statsText(_ counts: ArtistDetail.Counts?) -> String? {
        guard let counts else { return nil }

        var parts: [String] = []
        if counts.tracks > 0 {
            parts.append(TrackCountText.tracks(counts.tracks))
        }
        if counts.directAlbums > 0 {
            parts.append(TrackCountText.albums(counts.directAlbums))
        }

        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Секции

    private func trackList(_ tracks: [Track]) -> some View {
        GlassCard(cornerRadius: 24, padding: 8) {
            LazyVStack(spacing: 0) {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    row(track, in: tracks, index: index)

                    if index < tracks.count - 1 {
                        Rectangle()
                            .fill(Color.white.opacity(0.07))
                            .frame(height: 0.5)
                            .padding(.leading, 68)
                    }
                }
            }
        }
    }

    private func row(_ track: Track, in tracks: [Track], index: Int) -> some View {
        let isCurrent = player.currentTrack?.id == track.id

        return TrackRowView(
            track: track,
            isCurrent: isCurrent,
            isPlaying: isCurrent && player.isPlaying,
            onTap: { play(tracks, from: index) }
        )
    }

    private func play(_ tracks: [Track], from index: Int) {
        guard tracks.indices.contains(index) else { return }
        player.play(tracks: tracks, startAt: index)
    }

    private func albumsSection(_ albums: [Album]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            GlassSectionHeader("Альбомы")

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 14),
                    GridItem(.flexible(), spacing: 14)
                ],
                alignment: .leading,
                spacing: 18
            ) {
                ForEach(albums) { album in
                    Button {
                        Haptics.selection()
                        openedAlbum = album
                    } label: {
                        albumCard(album)
                    }
                    .buttonStyle(PressableStyle(scale: 0.97))
                }
            }
        }
    }

    private func albumCard(_ album: Album) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CachedAsyncImage(url: album.artworkURL) {
                ZStack {
                    Color.white.opacity(0.07)
                    Image(systemName: "square.stack")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.white.opacity(0.25))
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            }

            Text(album.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tone.primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 32, alignment: .topLeading)

            if let year = album.year {
                Text(String(year))
                    .font(.caption2)
                    .foregroundStyle(tone.tertiary)
            }
        }
    }

    // MARK: - Состояния

    private var headerSkeleton: some View {
        HStack(alignment: .top, spacing: 16) {
            Circle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 120, height: 120)

            VStack(alignment: .leading, spacing: 10) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.white.opacity(0.12))
                    .frame(height: 16)

                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.white.opacity(0.07))
                    .frame(width: 140, height: 10)
            }
            .padding(.top, 8)

            Spacer(minLength: 0)
        }
        .accessibilityHidden(true)
    }

    private var skeletonList: some View {
        GlassCard(cornerRadius: 24, padding: 8) {
            VStack(spacing: 0) {
                ForEach(0..<6, id: \.self) { _ in
                    SkeletonArtistTrackRow()
                }
            }
        }
        .accessibilityHidden(true)
    }

    private var emptyCard: some View {
        EmptyStateCard(
            systemImage: "person",
            title: "Пока пусто",
            message: "Сервер не вернул ни популярных треков, ни альбомов."
        )
    }
}

/// Скелетон строки, совпадающий по геометрии с `TrackRowView`.
private struct SkeletonArtistTrackRow: View {
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