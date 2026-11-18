import Foundation

struct Album: Codable, Identifiable, Equatable, Sendable {
    let id: Int
    let title: String
    let year: Int?
    let trackCount: Int?
    let coverUri: String?
    let artists: [Artist]?

    enum CodingKeys: String, CodingKey {
        case id, title, year, trackCount, coverUri, artists
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeFlexibleInt(forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Без названия"
        year = container.decodeFlexibleIntIfPresent(forKey: .year)
        trackCount = container.decodeFlexibleIntIfPresent(forKey: .trackCount)
        coverUri = try container.decodeIfPresent(String.self, forKey: .coverUri)
        artists = try container.decodeIfPresent([Artist].self, forKey: .artists)
    }

    var artworkURL: URL? {
        Artwork.url(from: coverUri)
    }
}
