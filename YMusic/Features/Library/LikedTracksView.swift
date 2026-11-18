import SwiftUI

/// Полный список «Мне нравится». Использует ту же пагинацию, что и каталог:
/// `MusicCatalogProviding.likedPage(offset:limit:)`, но вынесенную в
/// `LikedTracksViewModel`, чтобы не дублировать логику страниц в двух местах.
struct LikedTracksView: View {
    @StateObject private var viewModel: LikedTracksViewModel

    @EnvironmentObject private var player: AudioPlayer
    @Environment(\.contentTone) private var tone
    @Environment(\.dismiss) private var dismiss

    init(userID: Int) {
        _viewModel = StateObject(wrappedValue: LikedTracksViewModel(userID: userID))
    }

    var body: some View {
        DynamicBackground(
            imageURL: viewModel.tracks.first?.artworkURL,
            cacheKey: viewModel.tracks.first?.artworkURL?.absoluteString ?? "liked-tracks",
            fallback: .brand
        ) {
            VStack(spacing: 0) {
                topBar

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        Group {
                            switch viewModel.state {
                            case .idle, .loading:
                                skeleton

                            case .loaded(let tracks):
                                if tracks.isEmpty {
                                    emptyCard
                                } else {
                                    list(tracks)
                                }

                            case .failed(let error):
                                errorCard(error)
                            }
                        }
                        .transition(.opacity)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
                    .padding(.bottom, 40)
                    .animation(.easeInOut(duration: 0.25), value: stateKey)
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

            Text("Мне нравится")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(tone.primary)

            Spacer()

            Color.clear.frame(width: 40, height: 40)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // MARK: - Список

    private func list(_ tracks: [Track]) -> some View {
        GlassCard(cornerRadius: 24, padding: 8) {
            VStack(spacing: 0) {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    row(track, tracks: tracks)

                    if index < tracks.count - 1 {
                        Rectangle()
                            .fill(Color.white.opacity(0.07))
                            .frame(height: 0.5)
                            .padding(.leading, 68)
                    }
                }

                if viewModel.isLoadingMore {
                    ProgressView()
                        .tint(tone.secondary)
                        .padding(.vertical, 12)
                }
            }
        }
    }

    private func row(_ track: Track, tracks: [Track]) -> some View {
        let isCurrent = player.currentTrack?.id == track.id

        return TrackRowView(
            track: track,
            isCurrent: isCurrent,
            isPlaying: isCurrent && player.isPlaying,
            onTap: { player.play(track: track, in: tracks) },
            onUnlike: { viewModel.remove(trackID: $0.id) }
        )
        .onAppear {
            Task { await viewModel.loadMoreIfNeeded(currentID: track.id) }
        }
    }

    // MARK: - Состояния

    private var stateKey: Int {
        switch viewModel.state {
        case .idle: return 0
        case .loading: return 1
        case .loaded: return 2
        case .failed: return 3
        }
    }

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
        ErrorStateCard(error: error, context: .track) {
            Task { await viewModel.retry() }
        }
    }

    private var emptyCard: some View {
        EmptyStateCard(
            systemImage: "heart",
            title: "Пока ничего не лайкнуто",
            message: "Сердечко на строке трека добавит его сюда, а треки из «Мне нравится» попадут в очередь.",
            actionTitle: "Обновить",
            action: { Task { await viewModel.retry() } }
        )
    }
}

/// Скелетон строки: повторяет геометрию `TrackRowView`, чтобы список не «прыгал».
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
