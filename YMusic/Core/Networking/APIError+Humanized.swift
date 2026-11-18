import Foundation

/// Человеческий текст ошибки для UI. Сырые `localizedDescription`
/// (`HTTP 502: ...`, `Ошибка разбора ответа: ...`) в интерфейс не попадают:
/// они только логируются в `os.Logger`.
extension APIError {
    /// Где показывается ошибка: от контекста зависит текст 404
    /// (у трека — «удалён из каталога», у экрана — «не найдено»).
    enum Context: Sendable, Equatable {
        case generic
        case track
        case playlist
        case album
        case artist
        case search
    }

    /// Отмена запроса — не ошибка для пользователя: такие состояния
    /// вью-модели не публикуют, а карточки ошибок не показывают.
    var isCancellation: Bool {
        if case .cancelled = self { return true }
        return false
    }

    func humanizedTitle(context: Context = .generic) -> String {
        switch self {
        case .transport(let urlError):
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "Нет подключения"
            case .timedOut:
                return "Сервер не отвечает"
            default:
                return "Проблемы с сетью"
            }

        case .unauthorized:
            return "Сессия истекла"

        case .http(let status, _):
            switch status {
            case 401:
                return "Сессия истекла"
            case 403:
                return "Доступ закрыт"
            case 404:
                return context == .track ? "Трек недоступен" : "Не найдено"
            case 429:
                return "Слишком много запросов"
            case 500...599:
                return "Сервер временно недоступен"
            default:
                return "Ошибка сервера"
            }

        case .decoding, .missingResult:
            return "Неожиданный ответ сервера"

        case .cancelled:
            return "Запрос отменён"

        case .unavailable:
            return "Недоступно для аккаунта"

        case .unknown, .invalidURL:
            return "Не удалось загрузить"
        }
    }

    func humanizedDescription(context: Context = .generic) -> String {
        switch self {
        case .transport(let urlError):
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "Нет подключения к интернету"
            case .timedOut:
                return "Сервер не отвечает. Попробуйте ещё раз через минуту."
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "Не удаётся связаться с сервером. Проверьте подключение."
            case .secureConnectionFailed, .serverCertificateUntrusted:
                return "Проблема с защищённым соединением. Попробуйте позже."
            default:
                return "Сеть недоступна. Проверьте подключение к интернету."
            }

        case .unauthorized:
            return "Сессия истекла — войти заново"

        case .http(let status, _):
            switch status {
            case 401:
                return "Сессия истекла — войти заново"
            case 403:
                return "Сервер закрыл доступ к этому контенту."
            case 404:
                return context == .track
                    ? "Трек удалён из каталога"
                    : "На сервере больше нет этого содержимого."
            case 429:
                return "Слишком много запросов — попробуйте позже."
            case 500...599:
                return "Сервер временно недоступен"
            default:
                return "Сервер вернул ошибку \(status). Попробуйте ещё раз."
            }

        case .decoding:
            return "Сервер вернул неожиданный ответ"

        case .missingResult:
            return "Сервер вернул неожиданный ответ"

        case .cancelled:
            return "Запрос отменён"

        case .unavailable(let message):
            return message

        case .unknown:
            return "Что-то пошло не так. Попробуйте ещё раз."

        case .invalidURL:
            return "Внутренняя ошибка адреса запроса. Сообщите разработчику."
        }
    }

    /// Иконка статуса. Только символы, доступные на iOS 15.
    var humanizedIcon: String {
        switch self {
        case .transport(let urlError):
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "wifi.slash"
            case .timedOut:
                return "clock"
            default:
                return "exclamationmark.triangle"
            }
        case .unauthorized:
            return "lock.slash"
        case .http(let status, _):
            switch status {
            case 401:
                return "lock.slash"
            case 404:
                return "questionmark.circle"
            default:
                return "exclamationmark.triangle"
            }
        case .unavailable:
            return "lock.fill"
        case .cancelled:
            return "xmark.circle"
        case .decoding, .missingResult, .unknown, .invalidURL:
            return "exclamationmark.triangle"
        }
    }

    #if DEBUG
    /// Для отладки: первые 100 символов сырого описания. В UI не выводится.
    var debugDetail: String? {
        String(localizedDescription.prefix(100))
    }
    #endif
}