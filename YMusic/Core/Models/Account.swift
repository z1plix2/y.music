import Foundation

/// `GET /account/about`
struct Account: Decodable, Equatable {
    let uid: Int
    let login: String?
    let displayName: String?
    let fullName: String?
    let plus: PlusStatus?

    struct PlusStatus: Decodable, Equatable {
        let hasPlus: Bool?
        let isTutorialCompleted: Bool?
    }

    /// То, что реально вернул сервер. Не подменяем: клиент показывает
    /// фактический статус подписки.
    var hasPlus: Bool { plus?.hasPlus ?? false }

    var title: String { displayName ?? fullName ?? login ?? "Аккаунт \(uid)" }
}
