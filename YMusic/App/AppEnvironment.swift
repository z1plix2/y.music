import Combine
import Foundation

/// Корень сборки зависимостей. Экраны получают `APIManager`/`TokenStore`
/// отсюда, а не создают свои экземпляры — иначе появится несколько
/// независимых `URLSession` и рассинхрон токена.
///
/// `@MainActor`: статический `shared` не-`Sendable` типа иначе не проходит
/// проверку конкурентности Swift 6.
@MainActor
final class AppEnvironment: ObservableObject {
    static let shared = AppEnvironment()

    let api: APIManager
    let tokens: TokenStore

    init(api: APIManager = .shared, tokens: TokenStore = .shared) {
        self.api = api
        self.tokens = tokens
    }
}
