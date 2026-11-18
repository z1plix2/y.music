import Foundation

/// Провайдер для проверки UI без сети: каждый трек «играет» локальный файл.
///
/// Это не фейковый стриминг и не обход подписки — просто подмена источника,
/// чтобы проверить прогресс, паузу, очередь и переходы. Включается одной
/// строкой в `YMusicApp` (см. ответ Фазы 4, п. 7) и удаляется из бандла.
struct BundledDemoStreamProvider: AudioStreamProviding {
    let resourceName: String
    let fileExtension: String

    init(resourceName: String = "demo-track", fileExtension: String = "m4a") {
        self.resourceName = resourceName
        self.fileExtension = fileExtension
    }

    func stream(for track: Track, maxBitrate: Int) async throws -> AudioStream {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: fileExtension) else {
            throw APIError.unavailable(
                "Демо-файл \(resourceName).\(fileExtension) не найден в бандле."
            )
        }
        return .full(url)
    }
}
