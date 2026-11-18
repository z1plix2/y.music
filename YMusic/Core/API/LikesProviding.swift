import Foundation

/// Лайки треков. Отдельный протокол, чтобы `LikeStore` не зависел от
/// конкретных путей и в превью работал `InMemoryLikesProvider`.
protocol LikesProviding: Sendable {
    func likedTrackIDs(userID: Int) async throws -> [Int]
    func addLike(track: Track, userID: Int) async throws
    func removeLike(track: Track, userID: Int) async throws
}

/// Реализация на подтверждённых ручках:
/// - `GET  /users/{uid}/likes/tracks`
/// - `POST /users/{uid}/likes/tracks/add-multiple`  (form: `track-ids`)
/// - `POST /users/{uid}/likes/tracks/remove`        (form: `track-ids`)
actor YandexLikesProvider: LikesProviding {
    static let shared = YandexLikesProvider()

    private let api: APIManager

    init(api: APIManager = .shared) {
        self.api = api
    }

    func likedTrackIDs(userID: Int) async throws -> [Int] {
        try await api.likedTrackIDs(userID: userID)
    }

    func addLike(track: Track, userID: Int) async throws {
        try await api.like(
            trackID: track.id,
            userID: userID,
            albumID: track.albums?.first?.id
        )
    }

    func removeLike(track: Track, userID: Int) async throws {
        try await api.unlike(
            trackID: track.id,
            userID: userID,
            albumID: track.albums?.first?.id
        )
    }
}
