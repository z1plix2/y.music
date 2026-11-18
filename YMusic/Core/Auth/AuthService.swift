import AuthenticationServices
import Combine
import Foundation
import UIKit

/// Вход через Яндекс и хранение сессии.
///
/// Поток: `ASWebAuthenticationSession` → системный Safari → редирект на
/// `ymusic://oauth?code=...` → обмен кода на токен (`/token`) → токен в
/// Keychain → проверка `/account/about` → `state = .signedIn`.
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

    var isConfigured: Bool { config.isConfigured }

    private let api: APIManager
    private let tokens: TokenStore
    private let config: AuthConfig
    private let presenter = WebAuthenticationPresenter()
    private var webSession: ASWebAuthenticationSession?

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
    func restore() async {
        guard await api.isAuthorized else {
            state = .signedOut
            return
        }
        await refreshAccount()
    }

    func signIn() async {
        guard !isAuthenticating else { return }
        errorMessage = nil
        isAuthenticating = true
        defer { isAuthenticating = false }

        do {
            let token = try await requestToken()
            try await tokens.save(token)
            await refreshAccount()
        } catch AuthError.cancelled {
            // Пользователь закрыл окно Safari — это не ошибка.
            return
        } catch {
            errorMessage = message(for: error)
        }
    }

    func signOut() async {
        await api.signOut()
        errorMessage = nil
        state = .signedOut
    }

    func clearError() {
        errorMessage = nil
    }

    // MARK: - Сессия

    private func refreshAccount() async {
        do {
            let account = try await api.accountAbout()
            state = .signedIn(account)
        } catch {
            if let apiError = error as? APIError, apiError.requiresReauthentication {
                await api.signOut()
                state = .signedOut
                errorMessage = "Сессия истекла — войдите снова."
            } else {
                state = .signedOut
                errorMessage = message(for: error)
            }
        }
    }

    // MARK: - OAuth

    private func requestToken() async throws -> YandexToken {
        guard config.isConfigured else { throw AuthError.notConfigured }
        guard let authURL = makeAuthorizeURL() else { throw AuthError.cannotStart }

        let callbackURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: config.callbackScheme
            ) { url, error in
                if let error {
                    if let authError = error as? ASWebAuthenticationSessionError,
                       authError.code == .canceledLogin {
                        continuation.resume(throwing: AuthError.cancelled)
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                guard let url else {
                    continuation.resume(throwing: AuthError.missingCallback)
                    return
                }
                continuation.resume(returning: url)
            }

            session.presentationContextProvider = presenter
            // false — используем cookies Safari, чтобы Яндекс не спрашивал
            // пароль на каждом входе. true — приватная сессия без cookie.
            session.prefersEphemeralWebBrowserSession = false

            self.webSession = session
            if !session.start() {
                continuation.resume(throwing: AuthError.cannotStart)
            }
        }

        webSession = nil
        return try await resolveToken(from: callbackURL)
    }

    private func makeAuthorizeURL() -> URL? {
        var components = URLComponents(url: config.authorizeURL, resolvingAgainstBaseURL: false)
        var items = [
            // `code` + последующий обмен на токен через `/token`
            // (`exchange(code:)`). Implicit-поток (`response_type=token`)
            // Яндекс для новых приложений не отдаёт.
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI)
        ]
        // Если права не заданы, Яндекс выдаёт токен с правами, указанными
        // при регистрации приложения. Пустой `scope` отправлять нельзя.
        if !config.scopes.isEmpty {
            items.append(URLQueryItem(name: "scope", value: config.scopes.joined(separator: " ")))
        }
        components?.queryItems = items
        return components?.url
    }

    /// Токен приходит во фрагменте (`#access_token=...`), поэтому
    /// `URLComponents.queryItems` его не видит — разбираем fragment вручную.
    private func resolveToken(from url: URL) async throws -> YandexToken {
        let items = Self.parameters(from: url)
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }

        if let oauthError = value("error") {
            throw AuthError.oauth(value("error_description") ?? oauthError)
        }

        if let accessToken = value("access_token"), !accessToken.isEmpty {
            let expiresIn = value("expires_in").flatMap(Int.init)
            return YandexToken(
                accessToken: accessToken,
                // implicit flow не выдаёт refresh_token: по истечении срока
                // жизни токена нужен повторный вход.
                refreshToken: nil,
                expiresAt: expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
            )
        }

        if let code = value("code"), !code.isEmpty {
            return try await exchange(code: code)
        }

        throw AuthError.missingCallback
    }

    private func exchange(code: String) async throws -> YandexToken {
        guard !config.clientSecret.isEmpty else {
            throw AuthError.oauth("Сервер вернул code, но client_secret не задан")
        }

        var request = URLRequest(url: config.tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "client_secret", value: config.clientSecret)
        ]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw AuthError.oauth("Не удалось обменять code на токен")
        }

        let dto = try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
        return YandexToken(
            accessToken: dto.accessToken,
            refreshToken: dto.refreshToken,
            expiresAt: dto.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
        )
    }

    static func parameters(from url: URL) -> [URLQueryItem] {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [] }

        if let fragment = components.fragment,
           let fragmentComponents = URLComponents(string: "?" + fragment),
           let items = fragmentComponents.queryItems,
           !items.isEmpty {
            return items
        }

        return components.queryItems ?? []
    }

    // MARK: - Ошибки

    private func message(for error: Error) -> String {
        if let authError = error as? AuthError {
            return authError.localizedDescription
        }
        return error.localizedDescription
    }
}

// MARK: - Presentation anchor

/// Отдельный объект, потому что `ASWebAuthenticationPresentationContextProviding`
/// не изолирован на `MainActor`, а `AuthService` — изолирован.
final class WebAuthenticationPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let keyWindow = scenes.flatMap(\.windows).first { $0.isKeyWindow }
        return keyWindow ?? scenes.first?.windows.first ?? ASPresentationAnchor()
    }
}

enum AuthError: LocalizedError {
    case notConfigured
    case cancelled
    case missingCallback
    case cannotStart
    case oauth(String?)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "OAuth не настроен: добавьте YandexClientID и YandexRedirectURI в Secrets.plist."
        case .cancelled:
            return "Вход отменён"
        case .missingCallback:
            return "Яндекс вернул пустой ответ без токена"
        case .cannotStart:
            return "Не удалось открыть окно входа"
        case .oauth(let description):
            return description ?? "Яндекс отклонил вход"
        }
    }
}
