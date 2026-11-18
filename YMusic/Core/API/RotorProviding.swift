import Foundation

/// «Моя волна» (rotor). Отдельный протокол, чтобы `WaveViewModel` не зависел
/// от станции и конкретного пути, а в превью можно было подставить заглушку.
protocol RotorProviding: Sendable {
    /// Первые `limit` треков персональной волны.
    func waveTracks(limit: Int) async throws -> [Track]
}
