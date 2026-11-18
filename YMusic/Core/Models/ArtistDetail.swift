import Foundation

/// Артист для `ArtistDetailView`.
///
/// Собирается в `APIManager` из `GET /artists/{id}/brief-info`: это
/// единственная ручка, которая отдаёт имя, аватар, счётчики, популярные
/// треки и альбомы одним запросом (`GET /artists/{id}` в API нет).
///
/// Важно: `popularTracks` — не весь каталог (сервер отдаёт до 10),
/// `albums` — выборка, а не дискография. Поэтому UI не подписывает эти
/// секции числами из `counts`.
struct ArtistDetail: Codable, Identifiable, Equatable, Sendable {
    /// Общая статистика артиста из `artist.counts` (не размеры выборок).
    struct Counts: Codable, Equatable, Sendable {
        let tracks: Int
        let directAlbums: Int
        let alsoAlbums: Int
        let alsoTracks: Int

        init(tracks: Int, directAlbums: Int, alsoAlbums: Int, alsoTracks: Int) {
            self.tracks = tracks
            self.directAlbums = directAlbums
            self.alsoAlbums = alsoAlbums
            self.alsoTracks = alsoTracks
        }

        enum CodingKeys: String, CodingKey {
            case tracks, directAlbums, alsoAlbums, alsoTracks
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            tracks = container.decodeFlexibleIntIfPresent(forKey: .tracks) ?? 0
            directAlbums = container.decodeFlexibleIntIfPresent(forKey: .directAlbums) ?? 0
            alsoAlbums = container.decodeFlexibleIntIfPresent(forKey: .alsoAlbums) ?? 0
            alsoTracks = container.decodeFlexibleIntIfPresent(forKey: .alsoTracks) ?? 0
        }
    }

    let id: Int
    let name: String
    let avatarURL: URL?
    let counts: Counts?
    let popularTracks: [Track]
    let albums: [Album]
}