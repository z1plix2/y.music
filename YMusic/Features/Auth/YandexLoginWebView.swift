import SwiftUI
import WebKit

/// Экран входа: официальная страница Яндекс ID в `WKWebView`.
///
/// Возврат из OAuth приходит на `https://music.yandex.ru/#access_token=...`,
/// поэтому навигацию на этот хост перехватываем и закрываем окно, не загружая
/// тяжёлый сайт музыки.
struct YandexLoginView: View {
    let authorizeURL: URL
    let onToken: (YandexToken) -> Void
    let onError: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            OAuthWebView(
                url: authorizeURL,
                onToken: onToken,
                onError: onError
            )
        }
        .background(Color(.systemBackground))
    }

    private var header: some View {
        HStack {
            Button("Отмена", action: onCancel)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            Text("Яндекс ID")
                .font(.headline)

            Spacer()

            // Невидимый дубль кнопки: держит заголовок по центру.
            Text("Отмена")
                .font(.subheadline)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

// MARK: - Web view

private struct OAuthWebView: UIViewRepresentable {
    let url: URL
    let onToken: (YandexToken) -> Void
    let onError: (String) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Обычное хранилище: cookies Яндекс ID сохраняются между входами,
        // поэтому повторный вход не требует пароля.
        configuration.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Страницу загружаем один раз в makeUIView; обновлять нечего.
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let parent: OAuthWebView

        init(parent: OAuthWebView) {
            self.parent = parent
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            if isOAuthReturn(url) {
                decisionHandler(.cancel)
                if let token = YandexOAuthRedirect.token(from: url) {
                    parent.onToken(token)
                } else if let message = YandexOAuthRedirect.error(from: url) {
                    parent.onError(message)
                } else {
                    parent.onError(AuthError.missingToken.localizedDescription)
                }
                return
            }

            // Внешние схемы (приложения Яндекса, банки и т.п.) не открываем:
            // вход должен остаться внутри этого окна.
            if let scheme = url.scheme?.lowercased(), scheme != "http", scheme != "https" {
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            let nsError = error as NSError
            // Отменённая навигация — это наш перехват редиректа, не ошибка.
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
                return
            }
            parent.onError(error.localizedDescription)
        }

        /// Редирект после согласия: `music.yandex.ru/#access_token=...`.
        /// Проверяем и хост, и фрагмент — на случай зеркал домена.
        private func isOAuthReturn(_ url: URL) -> Bool {
            if url.host == AuthConfig.redirectHost {
                return true
            }
            guard let fragment = url.fragment else { return false }
            return fragment.contains("access_token=") || fragment.contains("error=")
        }
    }
}

// MARK: - Разбор редиректа

/// Чистые функции разбора URL возврата — без изоляции на главном
/// исполнителе, чтобы их можно было звать из делегата `WKWebView`.
enum YandexOAuthRedirect {
    static func token(from url: URL) -> YandexToken? {
        let items = parameters(from: url)
        guard
            let accessToken = items.first(where: { $0.name == "access_token" })?.value,
            !accessToken.isEmpty
        else {
            return nil
        }
        let expiresIn = items
            .first(where: { $0.name == "expires_in" })?
            .value
            .flatMap(Int.init)
        return YandexToken(
            accessToken: accessToken,
            // Implicit-поток не выдаёт refresh_token: после истечения срока
            // нужен повторный вход.
            refreshToken: nil,
            expiresAt: expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
        )
    }

    static func error(from url: URL) -> String? {
        let items = parameters(from: url)
        guard let name = items.first(where: { $0.name == "error" })?.value else {
            return nil
        }
        let description = items.first { $0.name == "error_description" }?.value
        return description ?? name
    }

    static func parameters(from url: URL) -> [URLQueryItem] {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return []
        }

        if let fragment = components.fragment,
           let fragmentComponents = URLComponents(string: "?" + fragment),
           let items = fragmentComponents.queryItems,
           !items.isEmpty {
            return items
        }

        return components.queryItems ?? []
    }
}