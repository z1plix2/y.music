import Foundation

/// Параметры входа.
///
/// Вход идёт через клиент официального приложения «Яндекс.Музыка»: только
/// его токены принимает внутренний API (`api.music.yandex.net`). Своему
/// OAuth-приложению Яндекс права `music:content` не выдаёт, поэтому вход
/// через собственный `client_id` упирается в
/// `403 missing-required-scopes` — проверено на живом сервере.
struct AuthConfig {
    /// `client_id` приложения «Яндекс.Музыка». Это не секрет: он публично
    /// известен и используется всеми сторонними клиентами.
    let clientID: String

    /// Хост, на который Яндекс возвращает пользователя после согласия.
    /// Токен приходит во фрагменте: `https://music.yandex.ru/#access_token=...`.
    static let redirectHost = "music.yandex.ru"

    /// Тот же `client_id`, что в `project.yml`/Info.plist не нужен: подпись
    /// Apple не требуется (TrollStore), а OAuth-секрет для implicit-потока
    /// не используется.
    static let yandexMusicClientID = "23cabbbdc6cd418abb4b39c32c41195d"

    private static let authorizeURLString = "https://oauth.yandex.ru/authorize"

    /// Implicit-поток (`response_type=token`): `redirect_uri` не передаём,
    /// он зарегистрирован за клиентом (музыка.яндекс).
    var authorizeURL: URL? {
        var components = URLComponents(string: Self.authorizeURLString)
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "token"),
            URLQueryItem(name: "client_id", value: clientID)
        ]
        return components?.url
    }

    static func fromBundle() -> AuthConfig {
        AuthConfig(clientID: yandexMusicClientID)
    }
}