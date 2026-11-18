import SwiftUI

/// Экран плейлиста: обложка, метаданные, «Играть всё» и список треков.
/// Открывается из каталога; очередь — треки плейлиста.
struct PlaylistDetailView: View {
    @StateObject private var viewModel: PlaylistDetailViewModel

    @EnvironmentObject private var player: AudioPlayer
    @Environment(\.contentTone) private var tone
    @Environment(\.dismiss) private var dismiss

    init(playlist: Playlist, userID: Int) {
        _viewModel = StateObject(
            wrappedValue: PlaylistDetailViewModel(playlist: playlist, userID: userID)
        )
    }

    private var playlist: Playlist { viewModel.playlist }

    var body: some View {
        DynamicBackground(
            imageURL: playlist.artworkURL,
            cacheKey: playlist.artworkURL?.absoluteString ?? "playlist-\(playlist.id)",
            fallback: .brand
        ) {
            VStack(spacing: 0) {
                topBar

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {
                        header

                        switch viewModel.state {
                        case .idle, .loading:
                            skeleton

                        case .loaded(let tracks):
                            if tracks.isEmpty {
                                emptyCard
                            } else {
                                if viewModel.isTruncated {
                                    truncationNotice(tracks.count)
                                }
                                trackList(tracks)
                            }

                        case .failed(let error):
                            errorCard(error)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
                    .padding(.bottom, 40)
                }
            }
        }
        .task { await viewModel.loadIfNeeded() }
    }

    // MARK: - Панель

    private var topBar: some View {
        HStack {
            GlassIconButton("chevron.down", label: "Закрыть") {
                dismiss()
            }

            Spacer()

            Text("Плейлист")
                .font(.caption.weight(.semibold))
                .foregroundStyle(tone.tertiary)

            Spacer()

            Color.clear.frame(width: 40, height: 40)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: - Шапка

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            CachedAsyncImage(url: playlist.artworkURL) {
                ZStack {
                    Color.white.opacity(0.07)
                    Image(systemName: "music.note.list")
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

            VStack(alignment: .leading, spacing: 8) {
                Text(playlist.title)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(tone.primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                if let owner = playlist.owner?.name, !owner.isEmpty {
                    Text(owner)
                        .font(.footnote)
                        .foregroundStyle(tone.secondary)
                        .lineLimit(1)
                }

                Text(trackCountText)
                    .font(.caption)
                    .foregroundStyle(tone.tertiary)

                if !viewModel.tracks.isEmpty {
                    GlassButton(
                        "Играть всё",
                        systemImage: "play.fill",
                        prominence: .prominent,
                        isEnabled: true
                    ) {
                        play(from: 0)
                    }
                    .padding(.top, 2)
                }
            }

            Spacer(minLength: 0)
        }
    }

    private var trackCountText: String {
        if viewModel.total > 0 { return "\(viewModel.total) треков" }
        return playlist.subtitle
    }

    private func truncationNotice(_ shown: Int) -> some View {
        GlassCard(cornerRadius: 18, padding: 14) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tone.secondary)

                Text("Показаны первые \(shown) из \(viewModel.total)")
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
                    row(track, index: index)

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

    private func row(_ track: Track, index: Int) -> some View {
        let isCurrent = player.currentTrack?.id == track.id

        return TrackRowView(
            track: track,
            isCurrent: isCurrent,
            isPlaying: isCurrent && player.isPlaying,
            onTap: { play(from: index) }
        )
    }

    private func play(from index: Int) {
        guard viewModel.tracks.indices.contains(index) else { return }
        player.play(tracks: viewModel.tracks, startAt: index)
    }

    // MARK: - Состояния

    private var skeleton: some View {
        GlassCard(cornerRadius: 24, padding: 8) {
            VStack(spacing: 0) {
                ForEach(0..<6, id: \.self) { _ in
                    SkeletonTrackRow()
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func errorCard(_ error: APIError) -> some View {
        ErrorStateCard(error: error, context: .playlist) {
            Task { await viewModel.retry() }
        }
    }

    private var emptyCard: some View {
        GlassCard(cornerRadius: 24, padding: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Плейлист пуст")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tone.primary)

                Text("Сервер не вернул ни одного трека.")
                    .font(.footnote)
                    .foregroundStyle(tone.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Скелетон строки, совпадающий по геометрии с `TrackRowView`.
private struct SkeletonTrackRow: View {
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
