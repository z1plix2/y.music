import Foundation

/// Конверт, в который Яндекс заворачивает почти все ответы:
/// `{"invocationInfo": {...}, "result": <T>}`.
struct Envelope<Value: Decodable>: Decodable {
    let result: Value?
}

extension KeyedDecodingContainer {
    /// Яндекс в разных ручках отдаёт `id` то числом, то строкой.
    func decodeFlexibleInt(forKey key: Key) throws -> Int {
        if let value = try? decode(Int.self, forKey: key) { return value }
        if let value = try? decode(String.self, forKey: key), let int = Int(value) { return int }
        if let value = try? decode(Double.self, forKey: key) { return Int(value) }
        throw DecodingError.dataCorruptedError(
            forKey: key,
            in: self,
            debugDescription: "Ожидалось число или строка с числом"
        )
    }

    func decodeFlexibleIntIfPresent(forKey key: Key) -> Int? {
        try? decodeFlexibleInt(forKey: key)
    }
}

/// Адреса обложек приходят без схемы и с плейсхолдером `%%` под размер:
/// `avatars.yandex.net/get-music-content/.../%%` → `https://.../600x600`.
enum Artwork {
    static func url(from uri: String?, size: Int = 600) -> URL? {
        guard let uri, !uri.isEmpty else { return nil }
        let path = uri.replacingOccurrences(of: "%%", with: "\(size)x\(size)")
        if path.hasPrefix("http") { return URL(string: path) }
        return URL(string: "https://" + path)
    }
}
