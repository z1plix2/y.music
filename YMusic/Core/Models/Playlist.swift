import Foundation

struct Playlist: Codable, Identifiable, Equatable, Sendable {
    let uid: Int
    let kind: Int
    let title: String
    let description: String?
    let trackCount: Int?
    let cover: Cover?
    let owner: Owner?
    let visibility: String?

    struct Cover: Codable, Equatable, Sendable {
        let uri: String?
        let type: String?

        enum CodingKeys: String, CodingKey {
            case uri, type
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            uri = try container.decodeIfPresent(String.self, forKey: .uri)
            type = try container.decodeIfPresent(String.self, forKey: .type)
        }
    }

    struct Owner: Codable, Equatable, Sendable {
        let uid: Int
        let name: String?
        let login: String?

        enum CodingKeys: String, CodingKey {
            case uid, name, login
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            uid = container.decodeFlexibleIntIfPresent(forKey: .uid) ?? 0
            name = try container.decodeIfPresent(String.self, forKey: .name)
            login = try container.decodeIfPresent(String.self, forKey: .login)
        }
    }

    var id: String { "\(owner?.uid ?? uid):\(kind)" }

    var artworkURL: URL? { Artwork.url(from: cover?.uri) }

    var subtitle: String {
        guard let trackCount, trackCount > 0 else { return "Плейлист" }
        return "\(trackCount) треков"
    }

    enum CodingKeys: String, CodingKey {
        case uid, kind, title, description, trackCount, cover, owner, visibility
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uid = container.decodeFlexibleIntIfPresent(forKey: .uid) ?? 0
        kind = container.decodeFlexibleIntIfPresent(forKey: .kind) ?? 0
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Плейлист"
        description = try container.decodeIfPresent(String.self, forKey: .description)
        trackCount = container.decodeFlexibleIntIfPresent(forKey: .trackCount)
        cover = try container.decodeIfPresent(Cover.self, forKey: .cover)
        owner = try container.decodeIfPresent(Owner.self, forKey: .owner)
        visibility = try container.decodeIfPresent(String.self, forKey: .visibility)
    }
}
