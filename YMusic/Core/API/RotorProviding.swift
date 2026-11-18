import Foundation

/// «Моя волна» (rotor). Отдельный протокол, чтобы `WaveViewModel` не зависел
/// от станции и конкретного пути, а в превью можно было подставить заглушку.
protocol RotorProviding: Sendable {
    /// Первые `limit` треков персональной волны.
    func waveTracks(limit: Int) async throws -> [Track]
}

/// Событие обратной связи сессии радио. Значения совпадают с полем `type`
/// из `SessionEvent` (`MarshalX/yandex-music-api`).
enum RotorFeedbackType: String, Sendable {
    case trackStarted
    case trackFinished
    case skip
    case like
    case dislike
}

/// Бесконечная волна через сессии радио.
///
/// Превью на главной (`RotorProviding.waveTracks`) остаётся на ручке станции:
/// создавать сессию ради пяти обложек расточительно. Само воспроизведение
/// идёт через сессию: партии треков и обратная связь.
protocol RotorSessionProviding: Sendable {
    /// `trackToStartFrom` — трек, с которого начнётся сессия (тап по превью).
    func startSession(seeds: [String], trackToStartFrom: String?) async throws -> RotorSessionStart

    func nextTracks(sessionID: String, queue: [String]) async throws -> RotorSessionBatch

    func sendFeedback(
        sessionID: String,
        type: RotorFeedbackType,
        trackID: String?,
        seconds: Double?,
        batchID: String?
    ) async throws
}