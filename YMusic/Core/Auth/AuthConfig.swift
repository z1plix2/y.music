import Foundation

/// OAuth-параметры приложения.
///
/// `clientID` / `clientSecret` берутся из `Secrets.plist` (в `.gitignore`),
/// а если его нет — из `Info.plist`. Секрет не должен попадать в репозиторий:
/// ключи приложения Яндекса выдаются на https://oauth.yandex.ru/client/new.
struct AuthConfig {
    let clientID: String
    let clientSecret: String
    let redirectURI: String
    let scopes: [String]

    let authorizeURL = URL(string: "https://oauth.yandex.ru/authorize")!
    let tokenURL = URL(string: "https://oauth.yandex.ru/token")!

    /// Схема редиректа — по ней `ASWebAuthenticationSession` перехватит
    /// возврат из браузера (Фаза 1).
    var callbackScheme: String {
        URLComponents(string: redirectURI)?.scheme ?? "ymusic"
    }

    var isConfigured: Bool {
        !clientID.isEmpty && !redirectURI.isEmpty
    }

    static func fromBundle(_ bundle: Bundle = .main) -> AuthConfig {
        let secrets = loadSecrets(from: bundle)

        func value(_ key: String) -> String {
            secrets[key] ?? bundle.object(forInfoDictionaryKey: key) as? String ?? ""
        }

        return AuthConfig(
            clientID: value("YandexClientID"),
            clientSecret: value("YandexClientSecret"),
            redirectURI: value("YandexRedirectURI"),
            scopes: (bundle.object(forInfoDictionaryKey: "YandexScopes") as? [String])
                ?? ["music:api-public"]
        )
    }

    private static func loadSecrets(from bundle: Bundle) -> [String: String] {
        guard
            let url = bundle.url(forResource: "Secrets", withExtension: "plist"),
            let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
            let dict = plist as? [String: String]
        else {
            return [:]
        }
        return dict
    }
}
