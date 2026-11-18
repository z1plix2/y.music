import Combine
import Foundation
import OSLog

/// Список «Мне нравится» с той же пагинацией, что и каталог:
/// `MusicCatalogProviding.likedPage(offset:limit:)`.
@MainActor
final class LikedTracksViewModel: ObservableObject {
    enum State {
        case idle
        case loading
        case loaded([Track])
        case failed(APIError)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var isLoadingMore = false
    @Published private(set) var hasMore = false

    let pageSize: Int

    private let userID: Int
    private let catalog: any MusicCatalogProviding
    private let logger = Logger(subsystem: "com.example.ymusic", category: "LikedVM")

    private var consumed = 0
    private var isLoading = false

    init(
        userID: Int,
        pageSize: Int = 50,
        catalog: any MusicCatalogProviding = YandexMusicCatalog.shared
    ) {
        self.userID = userID
        self.pageSize = pageSize
        self.catalog = catalog
    }

    var tracks: [Track] {
        if case .loaded(let tracks) = state { return tracks }
        return []
    }

    func loadIfNeeded() async {
        guard case .idle = state else { return }
        await load()
    }

    func retry() async {
        await load()
    }

    func loadMoreIfNeeded(currentID: Int) async {
        guard hasMore, !isLoadingMore, !isLoading else { return }
        guard tracks.last?.id == currentID else { return }
        await loadNextPage()
    }

    /// Убрали лайк с этого экрана — строка исчезает сразу.
    func remove(trackID: Int) {
        guard case .loaded(var tracks) = state else { return }
        tracks.removeAll { $0.id == trackID }
        state = .loaded(tracks)
    }

    // MARK: - Загрузка

    private func load() async {
        isLoading = true
        state = .loading
        defer { isLoading = false }

        do {
            let page = try await catalog.likedPage(userID: userID, offset: 0, limit: pageSize)
            guard !Task.isCancelled else { return }

            consumed = page.consumed
            hasMore = page.hasMore
            state = .loaded(page.tracks)
        } catch is CancellationError {
            return
        } catch let error as APIError {
            guard !Task.isCancelled else { return }
            logger.error("Лайки: \(error.localizedDescription, privacy: .public)")
            state = .failed(error)
        } catch {
            guard !Task.isCancelled else { return }
            logger.error("Лайки: \(error.localizedDescription, privacy: .public)")
            state = .failed(.unknown(error.localizedDescription))
        }
    }

    private func loadNextPage() async {
        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let page = try await catalog.likedPage(
                userID: userID,
                offset: consumed,
                limit: pageSize
            )
            guard !Task.isCancelled else { return }

            consumed = page.consumed
            hasMore = page.hasMore

            guard case .loaded(let existing) = state else { return }
            let known = Set(existing.map(\.id))
            let additions = page.tracks.filter { !known.contains($0.id) }
            state = .loaded(existing + additions)
        } catch is CancellationError {
            return
        } catch {
            // Догрузка не должна стирать список; повтор — на следующем появлении.
            logger.error("Лайки, страница: \(error.localizedDescription, privacy: .public)")
        }
    }
}
