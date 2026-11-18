import Foundation
import Security

/// Обёртка над Generic Password в Keychain.
///
/// Токен не должен лежать в UserDefaults: он даёт полный доступ к аккаунту.
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — читается после первой
/// разблокировки, не попадает в iCloud/бэкапы и не переносится на другое устройство.
struct KeychainStore {
    let service: String

    init(service: String = Bundle.main.bundleIdentifier ?? "com.example.ymusic") {
        self.service = service
    }

    /// Создаёт или перезаписывает запись.
    func set(_ data: Data, account: String) throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemCopyMatching(baseQuery as CFDictionary, nil)

        switch status {
        case errSecSuccess:
            let attributes: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError(status: updateStatus)
            }

        case errSecItemNotFound:
            var insertQuery = baseQuery
            insertQuery[kSecValueData as String] = data
            insertQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(insertQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError(status: addStatus)
            }

        default:
            throw KeychainError(status: status)
        }
    }

    func data(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound { return nil }

        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError(status: status)
        }
        return data
    }

    func remove(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

struct KeychainError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "неизвестная ошибка"
        return "Keychain (\(status)): \(message)"
    }
}
