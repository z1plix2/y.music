import Foundation

/// `POST /rotor/session/new` — ответ новой сессии радио.
///
/// Схема сверена с `MarshalX/yandex-music-api` (`RotorSession`):
/// `radioSessionId`, `batchId`, `sequence` — список звеньев, где `type`
/// равен `track`/`ad`. Повторяет `RotorTracks.Item`, но с идентификаторами
/// сессии, поэтому отдельный тип, а не расширение старого ответа станции.
struct RotorSessionStart: Decodable, Sendable {
    let radioSessionId: String?
    let batchId: String?
    let sequence: [RotorTracks.Item]?
    let terminated: Bool?

    enum CodingKeys: String, CodingKey {
        case radioSessionId, batchId, sequence, terminated
    }

    var tracks: [Track] {
        (sequence ?? [])
            .filter { $0.type == "track" }
            .compactMap(\.track)
    }
}

/// `POST /rotor/session/{id}/tracks` — следующая партия треков.
///
/// Для неизвестной сессии сервер не отдаёт ошибку, а выставляет
/// `unknownSession`; это надо отличать от пустой партии.
struct RotorSessionBatch: Decodable, Sendable {
    let batchId: String?
    let sequence: [RotorTracks.Item]?
    let terminated: Bool?
    let unknownSession: Bool?

    enum CodingKeys: String, CodingKey {
        case batchId, sequence, terminated, unknownSession
    }

    var tracks: [Track] {
        (sequence ?? [])
            .filter { $0.type == "track" }
            .compactMap(\.track)
    }
}