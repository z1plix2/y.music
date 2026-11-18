import Combine
import Foundation
import OSLog
import WidgetKit

/// Хранилище выбранной темы.
///
/// `@Published current` меняется только по действию пользователя, поэтому
/// подписчиков немного: корень приложения и экран настроек. Персист —
/// обычный `UserDefaults`, ключ `appTheme` (тот же, что читает виджет).
@MainActor
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()

    static let defaultsKey = "appTheme"
    private static let playerModeKey = "playerMode"
    private static let playerModeFromThemeKey = "playerModeFromTheme"

    @Published private(set) var current: AppTheme

    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.example.ymusic", category: "Theme")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let raw = defaults.string(forKey: Self.defaultsKey) ?? ""
        current = AppTheme(rawValue: raw) ?? .liquidGlass
    }

    func select(_ theme: AppTheme) {
        guard theme != current else { return }

        current = theme
        defaults.set(theme.rawValue, forKey: Self.defaultsKey)

        applyPlayerMode(for: theme)

        NotificationCenter.default.post(name: .themeDidChange, object: theme)
        WidgetCenter.shared.reloadAllTimelines()

        logger.debug("Тема: \(theme.rawValue, privacy: .public)")
    }

    /// Тема `.vinyl` включает вертушку по умолчанию. Если пользователь
    /// сам переключил режим плеера, его выбор не перетираем.
    private func applyPlayerMode(for theme: AppTheme) {
        if theme.prefersVinylPlayer {
            guard !defaults.bool(forKey: Self.playerModeFromThemeKey) else { return }
            defaults.set("vinyl", forKey: Self.playerModeKey)
            defaults.set(true, forKey: Self.playerModeFromThemeKey)
        } else if defaults.bool(forKey: Self.playerModeFromThemeKey) {
            defaults.set("standard", forKey: Self.playerModeKey)
            defaults.set(false, forKey: Self.playerModeFromThemeKey)
        }
    }
}