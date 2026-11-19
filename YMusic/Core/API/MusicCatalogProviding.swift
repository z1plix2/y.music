import Foundation

/// Источник данных для главного экрана.
///
/// Отдельный протокол, чтобы `CatalogViewModel` не зависел от Яндекс-специфики
/// и в превью/тестах можно было подставить статичный набор секций.
protocol MusicCatalogProviding: Sendable {
    /// Плейлисты + первая страница лайков.
    func home(userID: Int, likedPageSize: Int) async throws -> HomeFeed

    /// Следующая страница лайков. `offset` — сколько id уже показано.
    func likedPage(userID: Int, offset: Int, limit: Int) async throws -> LikedPage

    /// Треки одного плейлиста (`/users/{uid}/playlists/{kind}`).
    /// Возвращает также `total`, чтобы экран мог честно предупредить
    /// об усечённом ответе.
    func playlistTracks(userID: Int, kind: Int) async throws -> PlaylistTracks

    /// Артист: имя, аватар, счётчики, популярные треки и выборка альбомов
    /// (`/artists/{id}/brief-info`).
    func artistDetail(id: Int) async throws -> ArtistDetail

    /// Альбом с треками (`/albums/{id}/with-tracks`).
    func albumDetail(id: Int) async throws -> AlbumDetail
}

/// Главная одним ответом. `likedConsumed` и `hasMoreLiked` считаются по списку
/// id, а не по числу пришедших треков: часть id сервер может не отдать
/// (удалённые/недоступные), и это не означает конец списка.
struct HomeFeed: Sendable {
    let landings: [Landing]
    let likedConsumed: Int
    let hasMoreLiked: Bool
}

struct LikedPage: Equatable, Sendable {
    let tracks: [Track]
    let consumed: Int
    let hasMore: Bool
}

/// Треки плейлиста. `total` — `trackCount` из ответа плейлиста (или число
/// пришедших треков, если поля нет). `isTruncated` показываем плашкой.
struct PlaylistTracks: Equatable, Sendable {
    let tracks: [Track]
    let total: Int
    /// Версия плейлиста для изменяющих запросов (`nil`, если сервер её не отдал).
    var revision: Int?

    var isTruncated: Bool { total > tracks.count }
}
