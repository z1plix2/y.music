import Foundation

/// Версия приложения в одном месте: шапка, статистика и настройки читают
/// одно и то же значение вместо трёх копий `Bundle.main`.
enum AppInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    /// Готовая подпись для футеров и шапки.
    static var versionText: String {
        "YMusic v\(version)"
    }
}