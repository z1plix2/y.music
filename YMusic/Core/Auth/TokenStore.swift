import Foundation

/// Токен, который мы храним в Keychain.
struct YandexToken: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date()
    }
}

/// Единственное место, которое знает, где лежит токен.
///
/// Actor, потому что `APIClient` дёргает его конкурентно из разных задач.
///
/// Токен получен implicit-потоком (`response_type=token`), поэтому
/// `refresh_token` у него нет: продлить сессию нельзя, после истечения срока
/// нужен повторный вход. `refresh()` оставлен ради `APIClient`: на 401 он
/// получит `unauthorized`, а `AuthService` переведёт приложение на экран входа.
actor TokenStore {
    static let shared = TokenStore()

    private let keychain: KeychainStore
    private let account = "yandex.oauth.token"

    init(keychain: KeychainStore = KeychainStore()) {
        self.keychain = keychain
    }

    // MARK: - Чтение

    var hasToken: Bool {
        guard let token = persistedToken() else { return false }
        return !token.accessToken.isEmpty && !token.isExpired
    }

    /// Возвращает access token как есть. Просроченный токен не отдаём:
    /// иначе каждый запрос делал бы лишний round-trip с 401.
    func currentToken() -> String? {
        guard let token = persistedToken(), !token.isExpired else { return nil }
        return token.accessToken
    }

    // MARK: - Запись

    func save(_ token: YandexToken) throws {
        let data = try JSONEncoder().encode(token)
        try keychain.set(data, account: account)
    }

    func signOut() {
        keychain.remove(account: account)
    }

    // MARK: - Обновление

    /// Обновление невозможно: implicit-поток не выдаёт refresh token.
    func refresh() async throws -> String {
        throw APIError.unauthorized
    }

    // MARK: - Хранилище

    private func persistedToken() -> YandexToken? {
        guard
            let data = try? keychain.data(account: account),
            let token = try? JSONDecoder().decode(YandexToken.self, from: data)
        else {
            return nil
        }
        return token
    }
}