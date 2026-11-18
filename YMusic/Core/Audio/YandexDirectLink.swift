import CryptoKit
import Foundation

/// Прямая ссылка на аудиофайл.
///
/// `/download-info` отдаёт не ссылку, а URL XML-документа с полями
/// `host` / `path` / `ts` / `s`. Подпись — `md5(salt + path без ведущего "/" + s)`.
/// Ссылка живёт около минуты, поэтому её нельзя кэшировать: разрешаем
/// непосредственно перед передачей в `AVPlayer`.
enum YandexDirectLink {
    /// Соль из клиентского алгоритма Яндекса. Константа публично известна
    /// и не является ключом доступа: право на трек проверяет сервер.
    private static let salt = "XGRlBW9FXlekgbPrRHuSiA"

    struct Parts: Equatable {
        let host: String
        let path: String
        let timestamp: String
        let signature: String
    }

    static func url(from parts: Parts) -> URL? {
        guard parts.path.hasPrefix("/") else { return nil }

        let input = salt + String(parts.path.dropFirst()) + parts.signature
        let digest = Insecure.MD5.hash(data: Data(input.utf8))
        let sign = digest.map { String(format: "%02x", $0) }.joined()

        return URL(string: "https://\(parts.host)/get-mp3/\(sign)/\(parts.timestamp)\(parts.path)")
    }
}
