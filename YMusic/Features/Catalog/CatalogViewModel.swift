import Combine
import Foundation
import OSLog

@MainActor
final class CatalogViewModel: ObservableObject {
    enum State {
        case idle
        case loading
        case loaded([Landing])
        case failed(APIError)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var isRefreshing = false
    @Published private(set) var isLoadingMoreLiked = false
    @Published private(set) var hasMoreLiked = false

    /// Вызывается, если сервер вернул 401 после refresh. Реагирует `MainView`:
    /// разлогинивает через `AuthService.signOut()`.
    var onSessionExpired: (() -> Void)?

    /// Размер страницы лайков. Не «магическое число» во вьюхе: живёт в VM
    /// и передаётся в провайдер.
    let pageSize: Int

    private let userID: Int
    private let catalog: any MusicCatalogProviding
    private let logger = Logger(subsystem: "com.example.ymusic", category: "CatalogVM")

    private var likedConsumed = 0
    private var isLoadingMore = false

    init(
        userID: Int,
        pageSize: Int = 20,
        catalog: any MusicCatalogProviding = YandexMusicCatalog.shared
    ) {
        self.userID = userID
        self.pageSize = pageSize
        self.catalog = catalog
    }

    /// Первая загрузка: скелетоны вместо пустоты. «Недавнее» на главном
    /// проверяет это, чтобы показать локальные треки до ответа сети.
    var isLoadingInitial: Bool {
        switch state {
        case .idle, .loading: return true
        case .loaded, .failed: return false
        }
    }

    /// Обложка для `DynamicBackground`: самая первая доступная в фиде.
    var heroArtwork: (key: String, url: URL)? {
        guard case .loaded(let landings) = state else { return nil }

        for landing in landings {
            for item in landing.items {
                if let url = item.artworkURL {
                    return (url.absoluteString, url)
                }
            }
        }
        return nil
    }

    /// Все треки из секции лайков — очередь для плеера.
    var likedTracks: [Track] {
        guard case .loaded(let landings) = state,
              let landing = landings.first(where: { $0.kind == .likedTracks })
        else {
            return []
        }
        return landing.items.compactMap { item in
            if case .track(let track) = item { return track }
            return nil
        }
    }

    func loadIfNeeded() async {
        guard case .idle = state else { return }
        await load(showSkeleton: true)
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await load(showSkeleton: false)
    }

    func retry() async {
        if case .failed(let error) = state, error.requiresReauthentication {
            onSessionExpired?()
            return
        }
        await load(showSkeleton: true)
    }

    /// Вызывается `.onAppear` последней строки: догружаем следующую страницу.
    func loadMoreLikedIfNeeded(currentItemID: String) async {
        guard hasMoreLiked, !isLoadingMore else { return }
        guard case .loaded(let landings) = state,
              let liked = landings.first(where: { $0.kind == .likedTracks }),
              liked.items.last?.id == currentItemID
        else {
            return
        }
        await loadMoreLiked()
    }

    // MARK: - Загрузка

    private func load(showSkeleton: Bool) async {
        if showSkeleton {
            state = .loading
        }

        do {
            let feed = try await catalog.home(userID: userID, likedPageSize: pageSize)
            guard !Task.isCancelled else { return }

            likedConsumed = feed.likedConsumed
            hasMoreLiked = feed.hasMoreLiked
            state = .loaded(feed.landings)
        } catch is CancellationError {
            // Ушли с экрана: текущее состояние не трогаем.
            return
        } catch let apiError as APIError {
            guard !Task.isCancelled, !apiError.isCancellation else { return }
            logger.error("Каталог: \(apiError.localizedDescription, privacy: .public)")
            if apiError.requiresReauthentication {
                onSessionExpired?()
            }
            state = .failed(apiError)
        } catch {
            guard !Task.isCancelled else { return }
            logger.error("Каталог: \(error.localizedDescription, privacy: .public)")
            state = .failed(.unknown(error.localizedDescription))
        }
    }

    private func loadMoreLiked() async {
        guard hasMoreLiked, !isLoadingMore else { return }
        isLoadingMore = true
        isLoadingMoreLiked = true
        defer {
            isLoadingMore = false
            isLoadingMoreLiked = false
        }

        do {
            let page = try await catalog.likedPage(
                userID: userID,
                offset: likedConsumed,
                limit: pageSize
            )
            guard !Task.isCancelled else { return }

            likedConsumed = page.consumed
            hasMoreLiked = page.hasMore
            appendLiked(page.tracks)
        } catch is CancellationError {
            return
        } catch let apiError as APIError {
            // Ошибка догрузки не должна стирать уже показанный каталог:
            // оставляем hasMoreLiked, следующая попытка — на следующем появлении.
            logger.error("Лайки, страница: \(apiError.localizedDescription, privacy: .public)")
            if apiError.requiresReauthentication {
                onSessionExpired?()
            }
        } catch {
            logger.error("Лайки, страница: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func appendLiked(_ tracks: [Track]) {
        guard !tracks.isEmpty, case .loaded(var landings) = state else { return }
        guard let index = landings.firstIndex(where: { $0.kind == .likedTracks }) else { return }

        let existing = landings[index]
        let known = Set(existing.items.map(\.id))
        let additions = tracks.map(LandingItem.track).filter { !known.contains($0.id) }
        guard !additions.isEmpty else { return }

        landings[index] = Landing(
            id: existing.id,
            title: existing.title,
            subtitle: existing.subtitle,
            kind: existing.kind,
            items: existing.items + additions
        )
        state = .loaded(landings)
    }
}
