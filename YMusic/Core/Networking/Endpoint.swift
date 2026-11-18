import Foundation

/// Описание одного запроса: путь, параметры, тело. Сетевого кода здесь нет —
/// это позволяет тестировать сборку запроса без URLSession.
struct Endpoint {
    var path: String
    var method: HTTPMethod = .get
    var query: [String: String] = [:]
    var body: Data?
    var requiresAuth: Bool = true
    var headers: [String: String] = [:]

    func makeRequest(baseURL: URL, token: String?) throws -> URLRequest {
        let normalizedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard
            var components = URLComponents(
                url: baseURL.appendingPathComponent(normalizedPath),
                resolvingAgainstBaseURL: false
            )
        else {
            throw APIError.invalidURL(path)
        }

        if !query.isEmpty {
            components.queryItems = query
                .sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }

        guard let url = components.url else { throw APIError.invalidURL(path) }

        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.httpBody = body
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("YMusic/0.1 (iPhone; iOS)", forHTTPHeaderField: "User-Agent")

        if body != nil, method != .get {
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        if requiresAuth {
            guard let token, !token.isEmpty else { throw APIError.unauthorized }
            request.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
        }

        return request
    }
}

extension Endpoint {
    /// Яндекс ждёт JSON или form-urlencoded — для POST собираем JSON из словаря.
    static func json(
        _ path: String,
        method: HTTPMethod = .post,
        body: [String: String] = [:],
        query: [String: String] = [:]
    ) -> Endpoint {
        var data: Data?
        if !body.isEmpty {
            data = try? JSONSerialization.data(withJSONObject: body, options: [])
        }
        return Endpoint(path: path, method: method, query: query, body: data)
    }

    /// JSON-тело с вложенными объектами: сессии ротора принимают
    /// `{"seeds": [...]}` и `{"event": {...}}`, а не плоские строки.
    static func jsonObject(
        _ path: String,
        method: HTTPMethod = .post,
        body: [String: Any],
        headers: [String: String] = [:]
    ) -> Endpoint {
        let data = try? JSONSerialization.data(withJSONObject: body, options: [])
        return Endpoint(path: path, method: method, body: data, headers: headers)
    }

    /// Лайки Яндекс принимает именно как `application/x-www-form-urlencoded`
    /// (`track-ids=123:456`), а не JSON-телом.
    static func form(
        _ path: String,
        method: HTTPMethod = .post,
        fields: [String: String]
    ) -> Endpoint {
        var components = URLComponents()
        components.queryItems = fields
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }

        return Endpoint(
            path: path,
            method: method,
            body: components.percentEncodedQuery?.data(using: .utf8),
            headers: ["Content-Type": "application/x-www-form-urlencoded; charset=utf-8"]
        )
    }
}
