import Foundation

/// Ответ `GET /users/{uid}/playlists/list`.
///
/// Разные версии API отдают либо массив в `result`, либо объект
/// `{"playlists": [...]}`. Пробуем оба варианта, иначе один из них
/// молча ломал бы весь главный экран.
struct PlaylistsResponse: Decodable {
    let playlists: [Playlist]

    private enum CodingKeys: String, CodingKey {
        case playlists
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let array = try? container.decode([Playlist].self) {
            playlists = array
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        playlists = try container.decodeIfPresent([Playlist].self, forKey: .playlists) ?? []
    }
}
