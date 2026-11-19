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

    /// Повторяем только идемпотентные GET: POST-лайк или добавление в
    /// плейлист при повторе могли бы примениться дважды.
    private static let maxAttempts = 3
    private static let baseBackoff: UInt64 = 350_000_000
    /// Временные ответы сервера: их имеет смысл повторить с паузой.
    private static let retryableStatuses: Set<Int> = [429, 500, 502, 503, 504]

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
        var attempt = 0

        while true {
            let request = try endpoint.makeRequest(baseURL: baseURL, token: token)

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await dataTask(for: request)
            } catch APIError.cancelled {
                throw APIError.cancelled
            } catch APIError.transport(let urlError) {
                // Обрыв связи лечится повтором; GET безопасен, остальное — нет.
                if endpoint.method == .get, attempt < Self.maxAttempts - 1 {
                    attempt += 1
                    try await backoff(after: attempt)
                    continue
                }
                throw APIError.transport(urlError)
            } catch {
                throw error
            }

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
                let payload = try? decoder.decode(APIErrorPayload.self, from: data)
                if endpoint.method == .get,
                   Self.retryableStatuses.contains(http.statusCode),
                   attempt < Self.maxAttempts - 1 {
                    attempt += 1
                    try await backoff(after: attempt)
                    continue
                }
                throw APIError.http(status: http.statusCode, payload: payload)
            }
        }
    }

    /// Экспоненциальная пауза: 350 мс, 700 мс, … Лечит кратковременные
    /// сетевые сбои и не даёт «задудосить» сервер при массовых ошибках.
    private func backoff(after attempt: Int) async throws {
        let delay = Self.baseBackoff * UInt64(1 << (attempt - 1))
        try await Task.sleep(nanoseconds: delay)
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
