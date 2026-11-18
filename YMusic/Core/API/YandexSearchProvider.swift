import Foundation

/// Реализация на подтверждённой ручке `GET /search`:
/// `text`, `type=all`, `page`, `nocorrect=false`.
///
/// Схема ответа сверена с `MarshalX/yandex-music-api`
/// (`SearchResult` / `Section`): секции `tracks/artists/albums/playlists`
/// с вложенным `results`. Если живой ответ разойдётся, парсинг упадёт в
/// `APIError.decoding`, а экран покажет ошибку — «вечного loading» не будет.
actor YandexSearchProvider: SearchProviding {
    static let shared = YandexSearchProvider()

    private let api: APIManager

    init(api: APIManager = .shared) {
        self.api = api
    }

    func search(query: String, page: Int, limit: Int) async throws -> SearchResult {
        try await api.search(text: query, type: "all", page: page)
    }
}
