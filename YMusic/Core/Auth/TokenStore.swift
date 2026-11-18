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

/// Единственное место, которое знает, где лежит токен и как его обновлять.
///
/// Actor, потому что `APIClient` дёргает его конкурентно из разных задач.
/// Refresh — single-flight: если пять запросов одновременно получили 401,
/// в OAuth уйдёт один POST, остальные дождутся результата.
actor TokenStore {
    static let shared = TokenStore()

    private let keychain: KeychainStore
    private let config: AuthConfig
    private let session: URLSession
    private let account = "yandex.oauth.token"

    private var refreshTask: Task<YandexToken, Error>?

    init(
        config: AuthConfig = .fromBundle(),
        keychain: KeychainStore = KeychainStore(),
        session: URLSession = .shared
    ) {
        self.config = config
        self.keychain = keychain
        self.session = session
    }

    // MARK: - Чтение

    var hasToken: Bool {
        persistedToken()?.accessToken.isEmpty == false
    }

    /// Возвращает access token как есть. Если он протух, сервер ответит 401,
    /// `APIClient` вызовет `refresh()` и повторит запрос — лишний round-trip
    /// на каждый вызов нам не нужен.
    func currentToken() -> String? {
        persistedToken()?.accessToken
    }

    // MARK: - Запись

    func save(_ token: YandexToken) throws {
        let data = try JSONEncoder().encode(token)
        try keychain.set(data, account: account)
    }

    func signOut() {
        keychain.remove(account: account)
        refreshTask?.cancel()
        refreshTask = nil
    }

    // MARK: - Обновление

    func refresh() async throws -> String {
        if let existing = refreshTask {
            return try await existing.value.accessToken
        }

        let task = Task<YandexToken, Error> { try await self.performRefresh() }
        refreshTask = task
        defer { refreshTask = nil }

        let token = try await task.value
        return token.accessToken
    }

    private func performRefresh() async throws -> YandexToken {
        guard let stored = persistedToken(), let refreshToken = stored.refreshToken else {
            throw APIError.unauthorized
        }

        var request = URLRequest(url: config.tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "client_secret", value: config.clientSecret)
        ]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw APIError.http(status: -1, payload: nil)
        }
        guard (200...299).contains(http.statusCode) else {
            // Refresh-токен отозван: пользователю нужен повторный вход.
            throw APIError.http(
                status: http.statusCode,
                payload: try? JSONDecoder().decode(APIErrorPayload.self, from: data)
            )
        }

        let dto = try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
        let token = YandexToken(
            accessToken: dto.accessToken,
            refreshToken: dto.refreshToken ?? refreshToken,
            expiresAt: dto.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
        )
        try save(token)
        return token
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

/// Ответ `https://oauth.yandex.ru/token`.
struct OAuthTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int?
    let tokenType: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
    }
}
