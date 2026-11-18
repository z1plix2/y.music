import SwiftUI

/// Экран альбома: обложка, метаданные, «Играть всё» и треки.
///
/// Источник — `/albums/{id}/with-tracks`; треки приходят в `volumes`.
struct AlbumDetailView: View {
    @StateObject private var viewModel: AlbumDetailViewModel
    @State private var openedArtist: Artist?

    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var likes: LikeStore
    @Environment(\.contentTone) private var tone
    @Environment(\.dismiss) private var dismiss

    init(albumID: Int) {
        _viewModel = StateObject(wrappedValue: AlbumDetailViewModel(albumID: albumID))
    }

    var body: some View {
        DynamicBackground(
            imageURL: viewModel.album?.artworkURL,
            cacheKey: viewModel.album?.artworkURL?.absoluteString ?? "album-\(viewModel.albumID)",
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
        .sheet(item: $openedArtist) { artist in
            // TODO: на iOS 15 вложенный sheet может не открыться; если так —
            // заменить на callback с закрытием/переоткрытием.
            ArtistDetailView(artistID: artist.id)
                .environmentObject(player)
                .environmentObject(likes)
        }
    }

    // MARK: - Панель

    private var topBar: some View {
        GlassScreenHeader(
            title: "Альбом",
            subtitle: viewModel.album?.title,
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

        case .loaded(let album):
            header(album)

            if album.tracks.isEmpty {
                emptyCard
            } else {
                if isTruncated(album) {
                    truncationNotice(album)
                }
                trackList(album.tracks)
            }

        case .failed(let error):
            ErrorStateCard(error: error, context: .album) {
                Task { await viewModel.retry() }
            }
        }
    }

    // MARK: - Шапка

    private func header(_ album: AlbumDetail) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                artwork(album.artworkURL)

                VStack(alignment: .leading, spacing: 8) {
                    Text(album.title)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(tone.primary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)

                    artistLine(album.artists)

                    if let meta = metaText(album) {
                        Text(meta)
                            .font(.caption)
                            .foregroundStyle(tone.tertiary)
                    }
                }

                Spacer(minLength: 0)
            }

            if !album.tracks.isEmpty {
                GlassButton(
                    "Играть всё",
                    systemImage: "play.fill",
                    prominence: .prominent,
                    fullWidth: true
                ) {
                    play(album.tracks, from: 0)
                }
            }
        }
    }

    private func artwork(_ url: URL?) -> some View {
        CachedAsyncImage(url: url) {
            ZStack {
                Color.white.opacity(0.07)
                Image(systemName: "square.stack")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.white.opacity(0.25))
            }
        }
        .frame(width: 132, height: 132)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 16, x: 0, y: 10)
    }

    @ViewBuilder
    private func artistLine(_ artists: [Artist]) -> some View {
        if let artist = openableArtist(artists) {
            Button {
                Haptics.selection()
                openedArtist = artist
            } label: {
                HStack(spacing: 4) {
                    Text(artistNames(artists))
                        .font(.footnote)
                        .lineLimit(1)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(tone.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(scale: 0.97))
            .accessibilityLabel("Открыть артиста")
        } else if !artists.isEmpty {
            Text(artistNames(artists))
                .font(.footnote)
                .foregroundStyle(tone.secondary)
                .lineLimit(1)
        }
    }

    /// Открываем только артиста с настоящим id: у восстановленных треков
    /// из истории id равен 0, для него ручки нет.
    private func openableArtist(_ artists: [Artist]) -> Artist? {
        artists.first { $0.id > 0 }
    }

    private func artistNames(_ artists: [Artist]) -> String {
        let names = artists.map(\.name).filter { !$0.isEmpty }
        return names.isEmpty ? "Неизвестный исполнитель" : names.joined(separator: ", ")
    }

    private func metaText(_ album: AlbumDetail) -> String? {
        var parts: [String] = []
        if let year = album.year {
            parts.append(String(year))
        }
        if let count = album.trackCount, count > 0 {
            parts.append(TrackCountText.tracks(count))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func isTruncated(_ album: AlbumDetail) -> Bool {
        guard let count = album.trackCount else { return false }
        return count > album.tracks.count
    }

    private func truncationNotice(_ album: AlbumDetail) -> some View {
        GlassCard(cornerRadius: 18, padding: 14) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tone.secondary)

                Text("Показаны \(album.tracks.count) из \(album.trackCount ?? album.tracks.count)")
                    .font(.footnote)
                    .foregroundStyle(tone.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Список треков

    private func trackList(_ tracks: [Track]) -> some View {
        GlassCard(cornerRadius: 24, padding: 8) {
            VStack(spacing: 0) {
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

    // MARK: - Состояния

    private var headerSkeleton: some View {
        HStack(alignment: .top, spacing: 16) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .frame(width: 132, height: 132)

            VStack(alignment: .leading, spacing: 10) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.white.opacity(0.12))
                    .frame(height: 16)

                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.white.opacity(0.07))
                    .frame(width: 120, height: 10)

                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.white.opacity(0.07))
                    .frame(width: 80, height: 10)
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
                    SkeletonAlbumTrackRow()
                }
            }
        }
        .accessibilityHidden(true)
    }

    private var emptyCard: some View {
        EmptyStateCard(
            systemImage: "square.stack",
            title: "В альбоме нет треков",
            message: "Сервер не вернул ни одного доступного трека."
        )
    }
}

/// Скелетон строки, совпадающий по геометрии с `TrackRowView`.
private struct SkeletonAlbumTrackRow: View {
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