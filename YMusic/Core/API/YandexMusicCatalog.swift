import Foundation
import OSLog

/// Каталог на уже проверенных ручках:
/// - `GET /users/{uid}/playlists/list`
/// - `GET /users/{uid}/likes/tracks` → `GET /tracks?track-ids=...`
///
/// `/landing3` и `/rotor/station/...` намеренно не реализованы: схема блоков
/// лендинга и параметры ротора без ответа живого сервера легко превращаются
/// в парсер, который молча показывает пустоту. Возвращаемся к ним, когда
/// будет реальный JSON для сверки (см. TODO в README).
actor YandexMusicCatalog: MusicCatalogProviding {
    static let shared = YandexMusicCatalog()

    private let api: APIManager
    private let logger = Logger(subsystem: "com.example.ymusic", category: "Catalog")

    /// Список id лайков не меняется между страницами; держим его в памяти,
    /// чтобы каждый `loadMore` не тянул `/likes/tracks` заново.
    private var likedIDs: [Int: [Int]] = [:]

    init(api: APIManager = .shared) {
        self.api = api
    }

    func home(userID: Int, likedPageSize: Int) async throws -> HomeFeed {
        var sections: [Landing] = []
        var lastError: APIError?
        var consumed = 0
        var hasMore = false

        do {
            let playlists = try await api.playlists(userID: userID)
            if !playlists.isEmpty {
                sections.append(
                    Landing(
                        id: "playlists",
                        title: "Мои плейлисты",
                        subtitle: "\(playlists.count) в коллекции",
                        kind: .playlists,
                        items: playlists.map(LandingItem.playlist)
                    )
                )
            }
        } catch {
            lastError = Self.apiError(from: error)
            logger.error("Плейлисты: \(error.localizedDescription, privacy: .public)")
        }

        if Task.isCancelled { throw CancellationError() }

        do {
            let page = try await likedPage(userID: userID, offset: 0, limit: likedPageSize)
            consumed = page.consumed
            hasMore = page.hasMore

            if !page.tracks.isEmpty {
                sections.append(
                    Landing(
                        id: "liked",
                        title: "Мне нравится",
                        subtitle: "Последние лайки",
                        kind: .likedTracks,
                        items: page.tracks.map(LandingItem.track)
                    )
                )
            }
        } catch {
            lastError = Self.apiError(from: error)
            logger.error("Лайки: \(error.localizedDescription, privacy: .public)")
        }

        // Одна из секций упала — показываем то, что есть. Обе — отдаём ошибку.
        if sections.isEmpty, let lastError {
            throw lastError
        }

        return HomeFeed(landings: sections, likedConsumed: consumed, hasMoreLiked: hasMore)
    }

    func likedPage(userID: Int, offset: Int, limit: Int) async throws -> LikedPage {
        let ids = try await cachedLikedIDs(userID: userID)
        guard offset < ids.count else {
            return LikedPage(tracks: [], consumed: ids.count, hasMore: false)
        }

        let safeLimit = max(0, limit)
        let end = min(offset + safeLimit, ids.count)
        let slice = Array(ids[offset..<end])
        let tracks = try await api.tracks(ids: slice)

        return LikedPage(tracks: tracks, consumed: end, hasMore: end < ids.count)
    }

    func playlistTracks(userID: Int, kind: Int) async throws -> PlaylistTracks {
        try await api.playlistTracks(userID: userID, kind: kind)
    }

    // MARK: - Внутреннее

    private func cachedLikedIDs(userID: Int) async throws -> [Int] {
        if let cached = likedIDs[userID] {
            return cached
        }
        let ids = try await api.likedTrackIDs(userID: userID)
        likedIDs[userID] = ids
        return ids
    }

    /// После `like`/`unlike` кэш id устаревает — сбрасываем его точечно.
    func invalidateLikesCache(userID: Int) {
        likedIDs.removeValue(forKey: userID)
    }

    static func apiError(from error: Error) -> APIError {
        if let apiError = error as? APIError {
            return apiError
        }
        if error is CancellationError {
            return .cancelled
        }
        if let urlError = error as? URLError {
            return .transport(urlError)
        }
        return .unknown(error.localizedDescription)
    }
}
