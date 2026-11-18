import Combine
import Foundation

/// Вход через Яндекс и хранение сессии.
///
/// Поток: `YandexLoginView` (WKWebView) → официальная страница Яндекс ID →
/// редирект на `https://music.yandex.ru/#access_token=...` → перехват URL →
/// токен в Keychain → проверка `/account/status` → `state = .signedIn`.
///
/// Системный Safari (`ASWebAuthenticationSession`) здесь не подходит: клиент
/// официального приложения зарегистрирован с `https`-редиректом, а не с
/// собственным URL-схемой, поэтому возврат ловит сам web-view.
@MainActor
final class AuthService: NSObject, ObservableObject {

    enum SessionState: Equatable {
        case restoring
        case signedOut
        case signedIn(Account)
    }

    @Published private(set) var state: SessionState = .restoring
    @Published private(set) var isAuthenticating = false
    @Published private(set) var errorMessage: String?

    private let api: APIManager
    private let tokens: TokenStore
    private let config: AuthConfig

    /// URL страницы согласия для web-view. `nil` — конфиг сломан, но это
    /// возможно только при ошибке в коде: адрес собирается из констант.
    var authorizeURL: URL? { config.authorizeURL }

    init(
        api: APIManager = .shared,
        tokens: TokenStore = .shared,
        config: AuthConfig = .fromBundle()
    ) {
        self.api = api
        self.tokens = tokens
        self.config = config
        super.init()
    }

    // MARK: - Жизненный цикл

    /// Вызывается один раз при старте: если токен уже в Keychain,
    /// сразу подтягиваем аккаунт, без экрана логина.
    ///
    /// Прошлый аккаунт лежит в `UserDefaults`: сплэш не ждёт сеть, а
    /// `/account/about` догружается в фоне и просто уточняет данные.
    func restore() async {
        guard await api.isAuthorized else {
            clearCachedAccount()
            state = .signedOut
            return
        }

        if let cached = cachedAccount() {
            state = .signedIn(cached)
            await refreshAccount(keepingCachedSession: true)
        } else {
            await refreshAccount()
        }
    }

    /// Завершает вход: сохраняет токен, полученный из web-view, и загружает
    /// аккаунт. Ошибки показываем на экране логина.
    func completeSignIn(with token: YandexToken) async {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        errorMessage = nil
        defer { isAuthenticating = false }

        do {
            try await tokens.save(token)
            await refreshAccount()
        } catch {
            errorMessage = message(for: error)
        }
    }

    func signOut() async {
        await api.signOut()
        clearCachedAccount()
        errorMessage = nil
        state = .signedOut
    }

    func clearError() {
        errorMessage = nil
    }

    /// Ошибка внутри web-view (Яндекс отказал, сеть пропала) — показываем
    /// её на экране логина после закрытия окна.
    func reportLoginError(_ message: String) {
        errorMessage = message
    }

    // MARK: - Сессия

    private func refreshAccount(keepingCachedSession: Bool = false) async {
        do {
            let account = try await api.accountAbout()
            storeCachedAccount(account)
            state = .signedIn(account)
        } catch {
            if let apiError = error as? APIError, apiError.requiresReauthentication {
                await api.signOut()
                clearCachedAccount()
                state = .signedOut
                errorMessage = "Сессия истекла — войдите снова."
            } else if keepingCachedSession, case .signedIn = state {
                // Сеть пропала, но токен жив: остаёмся на кэшированном
                // аккаунте вместо выкидывания на экран логина.
                errorMessage = nil
            } else {
                state = .signedOut
                errorMessage = message(for: error)
            }
        }
    }

    // MARK: - Кэш аккаунта

    private var cacheKey: String { "auth.cachedAccount.v1" }

    private func cachedAccount() -> Account? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode(Account.self, from: data)
    }

    private func storeCachedAccount(_ account: Account) {
        guard let data = try? JSONEncoder().encode(account) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey)
    }

    private func clearCachedAccount() {
        UserDefaults.standard.removeObject(forKey: cacheKey)
    }

    // MARK: - Ошибки

    private func message(for error: Error) -> String {
        if let authError = error as? AuthError {
            return authError.localizedDescription
        }
        if let apiError = error as? APIError {
            return apiError.errorDescription ?? error.localizedDescription
        }
        return error.localizedDescription
    }
}

enum AuthError: LocalizedError {
    case cancelled
    case missingToken
    case cannotStart

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Вход отменён"
        case .missingToken:
            return "Яндекс вернул страницу без токена"
        case .cannotStart:
            return "Не удалось открыть страницу входа"
        }
    }
}