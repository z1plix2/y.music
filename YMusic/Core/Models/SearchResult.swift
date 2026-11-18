import Foundation

/// `GET /search?text=...&type=all&page=0&nocorrect=false`
///
/// Сервер отдаёт секции-обёртки `{ total, perPage, results }`; для UI
/// разворачиваем их в плоские массивы. Каждый массив может быть пустым —
/// «ничего не найдено» это не ошибка.
struct SearchResult: Decodable, Equatable, Sendable {
    let tracks: [Track]
    let artists: [Artist]
    let albums: [Album]
    let playlists: [Playlist]

    var isEmpty: Bool {
        tracks.isEmpty && artists.isEmpty && albums.isEmpty && playlists.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case tracks, artists, albums, playlists
    }

    /// Ручной init нужен для слияния страниц поиска: декодированный результат
    /// нельзя «дополнить» без конструкции.
    init(tracks: [Track], artists: [Artist], albums: [Album], playlists: [Playlist]) {
        self.tracks = tracks
        self.artists = artists
        self.albums = albums
        self.playlists = playlists
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tracks = Self.decode(from: container, forKey: .tracks)
        artists = Self.decode(from: container, forKey: .artists)
        albums = Self.decode(from: container, forKey: .albums)
        playlists = Self.decode(from: container, forKey: .playlists)
    }

    /// Отсутствующая или незнакомая секция — пустой массив, а не падение всего
    /// ответа: сервер может не вернуть, например, `artists`.
    private static func decode<T: Decodable>(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> [T] {
        guard let section = try? container.decodeIfPresent(Section<T>.self, forKey: key) else {
            return []
        }
        return section.results ?? []
    }

    struct Section<Item: Decodable>: Decodable {
        let total: Int?
        let perPage: Int?
        let results: [Item]?
    }
}
