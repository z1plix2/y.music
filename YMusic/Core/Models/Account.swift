import Foundation

/// Данные аккаунта, которые показывает приложение.
///
/// `uid` берётся из `/account/status`: в `/account/about` его больше нет
/// (там только `publicId`), а числовой uid нужен для лайков и плейлистов.
struct Account: Codable, Equatable {
    let uid: Int
    let login: String?
    let displayName: String?
    let fullName: String?
    let plus: PlusStatus?

    struct PlusStatus: Codable, Equatable {
        let hasPlus: Bool?
        let isTutorialCompleted: Bool?
    }

    /// То, что реально вернул сервер. Не подменяем: клиент показывает
    /// фактический статус подписки.
    var hasPlus: Bool { plus?.hasPlus ?? false }

    var title: String { displayName ?? fullName ?? login ?? "Аккаунт \(uid)" }
}

/// `GET /account/status`
struct AccountStatus: Decodable {
    struct Info: Decodable {
        let uid: Int
        let login: String?
        let displayName: String?
        let fullName: String?
    }

    let account: Info
    let plus: Account.PlusStatus?
}

extension Account {
    init(status: AccountStatus) {
        self.init(
            uid: status.account.uid,
            login: status.account.login,
            displayName: status.account.displayName,
            fullName: status.account.fullName,
            plus: status.plus
        )
    }
}