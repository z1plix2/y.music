import Foundation

/// Ответ `GET /rotor/station/{station}/tracks`.
///
/// Схема сверена с `MarshalX/yandex-music-api` (`StationTracksResult` /
/// `Sequence`): сервер отдаёт `sequence` — список элементов, где `type`
/// равен `track` или `ad`. Нас интересуют только `track`, и у рекламы
/// вложенного трека нет.
struct RotorTracks: Decodable, Sendable {
    struct Item: Decodable, Sendable {
        let type: String
        let track: Track?

        enum CodingKeys: String, CodingKey {
            case type, track
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // Незнакомый/рекламный элемент без `type` не должен ронять весь
            // ответ ротора: помечаем его `unknown` и отбрасываем ниже.
            type = try container.decodeIfPresent(String.self, forKey: .type) ?? "unknown"
            track = try container.decodeIfPresent(Track.self, forKey: .track)
        }
    }

    let sequence: [Item]

    /// Только музыкальные элементы, в порядке ротора.
    var tracks: [Track] {
        sequence
            .filter { $0.type == "track" }
            .compactMap(\.track)
    }
}
