import Foundation

/// Тело ошибки Яндекс.API: `{"error": {"name": "...", "message": "..."}}`
struct APIErrorPayload: Decodable {
    struct Body: Decodable {
        let name: String?
        let message: String?
    }

    let error: Body?

    var readable: String {
        [error?.name, error?.message]
            .compactMap { $0 }
            .joined(separator: ": ")
    }
}

enum APIError: LocalizedError {
    case invalidURL(String)
    case unauthorized
    case http(status: Int, payload: APIErrorPayload?)
    case decoding(DecodingError)
    case transport(URLError)
    case cancelled
    case missingResult
    /// Сервер не предложил ни одного играбельного варианта потока.
    /// Это не ошибка сети: у аккаунта нет прав на трек (обычно нужен Plus).
    case unavailable(String)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let path):
            return "Некорректный URL для пути \(path)"
        case .unauthorized:
            return "Требуется авторизация"
        case .http(let status, let payload):
            let details = payload?.readable
            return details.map { "HTTP \(status): \($0)" } ?? "HTTP \(status)"
        case .decoding(let error):
            return "Ошибка разбора ответа: \(error)"
        case .transport(let error):
            return "Сеть недоступна: \(error.localizedDescription)"
        case .cancelled:
            return "Запрос отменён"
        case .missingResult:
            return "Ответ не содержит поле result"
        case .unavailable(let message):
            return message
        case .unknown(let message):
            return message
        }
    }

    /// 401 после попытки refresh — токен отозван, нужен повторный вход.
    var requiresReauthentication: Bool {
        switch self {
        case .http(status: 401, payload: _), .unauthorized:
            return true
        default:
            return false
        }
    }

    /// Показываем «Требуется подписка», а не «Повторить».
    var isSubscriptionRequired: Bool {
        if case .unavailable = self { return true }
        return false
    }
}
