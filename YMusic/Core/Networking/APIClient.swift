import Foundation

/// Тонкий клиент над URLSession.
///
/// Задачи клиента:
/// - собрать `URLRequest` из `Endpoint`;
/// - подставить OAuth-токен из `TokenStore`;
/// - при 401 один раз обновить токен и повторить запрос;
/// - развернуть конверт `{"invocationInfo": ..., "result": ...}` в модель.
actor APIClient {
    private let baseURL: URL
    private let session: URLSession
    private let tokens: TokenStore
    private let decoder: JSONDecoder

    init(
        baseURL: URL = URL(string: "https://api.music.yandex.net")!,
        tokens: TokenStore,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.tokens = tokens
        self.session = session

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    // MARK: - Публичный интерфейс

    /// Запрос, ответ которого обёрнут в конверт с `result`.
    func send<T: Decodable>(_ endpoint: Endpoint, as type: T.Type) async throws -> T {
        let data = try await perform(endpoint)
        do {
            let envelope = try decoder.decode(Envelope<T>.self, from: data)
            guard let result = envelope.result else { throw APIError.missingResult }
            return result
        } catch let error as APIError {
            throw error
        } catch let error as DecodingError {
            throw APIError.decoding(error)
        }
    }

    /// Запрос без разбора тела (например, `POST /tracks/{id}/like`).
    @discardableResult
    func sendIgnoringResponse(_ endpoint: Endpoint) async throws -> Data {
        try await perform(endpoint)
    }

    // MARK: - Ядро

    private func perform(_ endpoint: Endpoint) async throws -> Data {
        var token: String?
        if endpoint.requiresAuth {
            token = await tokens.currentToken()
        }
        var didRefresh = false

        while true {
            let request = try endpoint.makeRequest(baseURL: baseURL, token: token)
            let (data, response) = try await dataTask(for: request)

            guard let http = response as? HTTPURLResponse else {
                throw APIError.http(status: -1, payload: nil)
            }

            switch http.statusCode {
            case 200...299:
                return data

            case 401 where endpoint.requiresAuth && !didRefresh:
                didRefresh = true
                token = try await tokens.refresh()

            default:
                throw APIError.http(
                    status: http.statusCode,
                    payload: try? decoder.decode(APIErrorPayload.self, from: data)
                )
            }
        }
    }

    private func dataTask(for request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw APIError.cancelled
        } catch let error as URLError {
            throw APIError.transport(error)
        }
    }
}
