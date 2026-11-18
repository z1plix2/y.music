import Foundation

/// `GET /users/{uid}/likes/tracks` — отдаёт только ссылки на треки,
/// сами треки запрашиваются пачкой через `GET /tracks`.
struct LikedTracks: Decodable {
    struct Library: Decodable {
        let tracks: [ShortTrack]?
    }

    struct ShortTrack: Decodable {
        let id: Int
        let albumId: Int?

        enum CodingKeys: String, CodingKey {
            case id, albumId
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeFlexibleInt(forKey: .id)
            albumId = container.decodeFlexibleIntIfPresent(forKey: .albumId)
        }
    }

    let library: Library?
}
