import Foundation

/// Один играбельный вариант трека.
///
/// `preview` — сервер сам пометил вариант как 30-секундный фрагмент.
/// Это не ошибка клиента и не повод что-то обходить: так Яндекс отдаёт трек,
/// на который у аккаунта нет полного права.
enum AudioStream: Equatable, Sendable {
    case full(URL)
    case preview(URL)

    var url: URL {
        switch self {
        case .full(let url), .preview(let url):
            return url
        }
    }
}

protocol AudioStreamProviding: Sendable {
    /// Разрешает трек в URL, который умеет играть `AVPlayer`.
    /// Бросает `APIError.unavailable`, если играть нечего.
    func stream(for track: Track, maxBitrate: Int) async throws -> AudioStream
}
