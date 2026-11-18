import Foundation

/// Ответ `GET /tracks/{id}/lyrics`: текст лежит не в самом ответе, а по
/// подписанной ссылке `download_url`. Формат — LRC с таймкодами либо
/// обычный текст, поэтому разбор делает `LyricsSheet`.
struct TrackLyricsMeta: Decodable {
    let downloadURL: String?
    let lyricID: Int?

    enum CodingKeys: String, CodingKey {
        case downloadURL = "download_url"
        case lyricID = "lyric_id"
    }
}