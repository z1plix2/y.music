import Foundation

/// `GET /tracks/{id}/download-info` — варианты потока для трека.
/// Сервер выдаёт только те качества, на которые есть право у аккаунта,
/// поэтому этот ответ — единственный честный источник «можно играть или нет».
struct DownloadInfo: Decodable, Equatable, Sendable {
    let codec: String
    let bitrateInKbps: Int
    let downloadInfoUrl: String
    let direct: Bool
    /// `true` — это 30-секундное превью, а не полный трек.
    let preview: Bool

    enum CodingKeys: String, CodingKey {
        case codec, bitrateInKbps, downloadInfoUrl, direct, preview
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        codec = try container.decodeIfPresent(String.self, forKey: .codec) ?? "mp3"
        bitrateInKbps = container.decodeFlexibleIntIfPresent(forKey: .bitrateInKbps) ?? 0
        downloadInfoUrl = try container.decodeIfPresent(String.self, forKey: .downloadInfoUrl) ?? ""
        direct = try container.decodeIfPresent(Bool.self, forKey: .direct) ?? false
        preview = try container.decodeIfPresent(Bool.self, forKey: .preview) ?? false
    }
}
