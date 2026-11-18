import Foundation

/// Секция главного экрана. Не Decodable: собирается в `YandexMusicCatalog`
/// из ответов нескольких ручек, а не приходит одним JSON-блоком.
struct Landing: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case playlists
        case likedTracks
    }

    let id: String
    let title: String
    let subtitle: String
    let kind: Kind
    let items: [LandingItem]
}

/// Карточка внутри секции: плейлист либо трек.
enum LandingItem: Identifiable, Equatable, Sendable {
    case playlist(Playlist)
    case track(Track)

    var id: String {
        switch self {
        case .playlist(let playlist): return "p-\(playlist.id)"
        case .track(let track): return "t-\(track.id)"
        }
    }

    var artworkURL: URL? {
        switch self {
        case .playlist(let playlist): return playlist.artworkURL
        case .track(let track): return track.artworkURL
        }
    }
}
