import SwiftUI

/// Экран плейлиста: обложка, метаданные, «Играть всё» и список треков.
/// Открывается из каталога; очередь — треки плейлиста.
struct PlaylistDetailView: View {
    @StateObject private var viewModel: PlaylistDetailViewModel

    @EnvironmentObject private var player: AudioPlayer
    @Environment(\.contentTone) private var tone
    @Environment(\.dismiss) private var dismiss

    /// Тап по артисту в шапке. По умолчанию ничего не делает: экран можно
    /// открыть откуда угодно, а навигацию решает вызывающий.
    var onOpenArtist: (Int) -> Void = { _ in }

    @State private var isRenamePresented = false
    @State private var renameDraft = ""

    init(
        playlist: Playlist,
        userID: Int,
        onOpenArtist: @escaping (Int) -> Void = { _ in }
    ) {
        _viewModel = StateObject(
            wrappedValue: PlaylistDetailViewModel(playlist: playlist, userID: userID)
        )
        self.onOpenArtist = onOpenArtist
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
                    VStack(alignment: .leading, spacing: 24) {
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
        .alert("Название плейлиста", isPresented: $isRenamePresented) {
            TextField("Название", text: $renameDraft)
            Button("Сохранить") {
                let draft = renameDraft
                Task { await viewModel.rename(to: draft) }
            }
            Button("Отмена", role: .cancel) { }
        } message: {
            Text("Как назвать плейлист?")
        }
        .alert(
            "Не удалось изменить",
            isPresented: Binding(
                get: { viewModel.mutationError != nil },
                set: { if !$0 { viewModel.mutationError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { viewModel.mutationError = nil }
        } message: {
            Text(viewModel.mutationError?.humanizedDescription(context: .playlist) ?? "")
        }
    }

    // MARK: - Панель

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            GlassScreenHeader(
                title: "Плейлист",
                subtitle: viewModel.title,
                onClose: { dismiss() }
            )

            if viewModel.canEdit {
                HStack(spacing: 16) {
                    Button {
                        Haptics.selection()
                        renameDraft = viewModel.title
                        isRenamePresented = true
                    } label: {
                        Label("Переименовать", systemImage: "pencil")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(tone.primary)
                    }

                    if viewModel.isMutating {
                        ProgressView().tint(tone.tertiary)
                    }

                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 4)
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
                Text(viewModel.title)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(tone.primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                if let artist = openableArtist {
                    Button {
                        Haptics.selection()
                        onOpenArtist(artist.id)
                    } label: {
                        HStack(spacing: 4) {
                            Text(artist.name)
                                .font(.footnote)
                                .lineLimit(1)

                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(tone.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle(scale: 0.97))
                    .accessibilityLabel("Открыть артиста \(artist.name)")
                } else if let owner = playlist.owner?.name, !owner.isEmpty {
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

    /// Первый трек с настоящим id артиста: у восстановленных из истории id 0.
    private var openableArtist: (id: Int, name: String)? {
        for track in viewModel.tracks {
            guard let artist = track.artists?.first(where: { $0.id > 0 }) else { continue }
            return (artist.id, artist.name)
        }
        return nil
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
            LazyVStack(spacing: 0) {
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
        let canEdit = viewModel.canEdit
        let lastIndex = viewModel.tracks.count - 1

        return TrackRowView(
            track: track,
            isCurrent: isCurrent,
            isPlaying: isCurrent && player.isPlaying,
            onTap: { play(from: index) },
            onOpenArtist: artistAction,
            onRemoveFromPlaylist: canEdit ? { Task { await viewModel.remove(at: index) } } : nil,
            onMoveUp: canEdit && index > 0
                ? { Task { await viewModel.move(from: index, to: index - 1) } }
                : nil,
            onMoveDown: canEdit && index < lastIndex
                ? { Task { await viewModel.move(from: index, to: index + 1) } }
                : nil
        )
    }

    private func play(from index: Int) {
        guard viewModel.tracks.indices.contains(index) else { return }
        player.play(tracks: viewModel.tracks, startAt: index)
    }

    private var artistAction: (() -> Void)? {
        guard let artist = openableArtist else { return nil }
        return { onOpenArtist(artist.id) }
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
        EmptyStateCard(
            systemImage: "music.note.list",
            title: "Плейлист пуст",
            message: "Сервер не вернул ни одного трека.",
            actionTitle: "Обновить",
            action: { Task { await viewModel.retry() } }
        )
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
