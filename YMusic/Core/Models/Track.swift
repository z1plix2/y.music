import Foundation

struct Track: Codable, Identifiable, Equatable, Sendable {
    let id: Int
    let realId: Int?
    let title: String
    let available: Bool
    let durationMs: Int?
    let artists: [Artist]?
    let albums: [Album]?
    let coverUri: String?
    let ogImage: String?

    /// Восстановление из `UserDefaults`: обложка уже абсолютным URL,
    /// поэтому лежит в `coverUri` — `Artwork.url` вернёт её как есть.
    init(
        id: Int,
        title: String,
        artistName: String,
        durationSeconds: Double,
        artworkURLString: String?
    ) {
        self.id = id
        self.realId = nil
        self.title = title
        self.available = true
        self.durationMs = durationSeconds > 0 ? Int((durationSeconds * 1000).rounded()) : nil
        self.artists = [Artist(id: 0, name: artistName)]
        self.albums = nil
        self.coverUri = artworkURLString
        self.ogImage = nil
    }

    enum CodingKeys: String, CodingKey {
        case id, realId, title, available, durationMs, artists, albums, coverUri, ogImage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeFlexibleInt(forKey: .id)
        realId = container.decodeFlexibleIntIfPresent(forKey: .realId)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Без названия"
        available = try container.decodeIfPresent(Bool.self, forKey: .available) ?? false
        durationMs = container.decodeFlexibleIntIfPresent(forKey: .durationMs)
        artists = try container.decodeIfPresent([Artist].self, forKey: .artists)
        albums = try container.decodeIfPresent([Album].self, forKey: .albums)
        coverUri = try container.decodeIfPresent(String.self, forKey: .coverUri)
        ogImage = try container.decodeIfPresent(String.self, forKey: .ogImage)
    }

    var duration: TimeInterval {
        guard let durationMs, durationMs > 0 else { return 0 }
        return Double(durationMs) / 1000
    }

    var durationText: String {
        guard let durationMs, durationMs > 0 else { return "--:--" }
        let totalSeconds = durationMs / 1000
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    var artistLine: String {
        let names = (artists ?? []).map(\.name).filter { !$0.isEmpty }
        return names.isEmpty ? "Неизвестный исполнитель" : names.joined(separator: ", ")
    }

    var artworkURL: URL? {
        Artwork.url(from: coverUri) ?? Artwork.url(from: albums?.first?.coverUri)
    }
}
