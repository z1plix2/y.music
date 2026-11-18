import Foundation

struct Artist: Codable, Identifiable, Equatable, Sendable {
    let id: Int
    let name: String
    let cover: Cover?
    let various: Bool?
    let composer: Bool?

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

    var artworkURL: URL? {
        Artwork.url(from: cover?.uri)
    }

    /// For reconstructed tracks (persistence, recents).
    init(id: Int, name: String) {
        self.id = id
        self.name = name
        self.cover = nil
        self.various = nil
        self.composer = nil
    }

    enum CodingKeys: String, CodingKey {
        case id, name, cover, various, composer
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // У части артистов id приходит строкой — не роняем весь трек из-за этого.
        id = container.decodeFlexibleIntIfPresent(forKey: .id) ?? 0
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Неизвестный исполнитель"
        cover = try container.decodeIfPresent(Cover.self, forKey: .cover)
        various = try container.decodeIfPresent(Bool.self, forKey: .various)
        composer = try container.decodeIfPresent(Bool.self, forKey: .composer)
    }
}
