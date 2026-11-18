import Combine
import Foundation
import SwiftUI

/// Настройки приложения в `UserDefaults`.
///
/// Один объект на всё приложение (синглтон + environment): экран настроек
/// пишет, корень читает тему, плеер — качество и кроссфейд. Никаких значений
/// «только в памяти»: каждое изменение сразу уходит на диск.
@MainActor
final class AppSettingsStore: ObservableObject {
    enum Theme: String, CaseIterable, Identifiable {
        case system
        case light
        case dark

        var id: String { rawValue }

        var title: String {
            switch self {
            case .system: return "Системная"
            case .light: return "Светлая"
            case .dark: return "Тёмная"
            }
        }

        var colorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }
    }

    enum AudioQuality: String, CaseIterable, Identifiable {
        case high
        case medium

        var id: String { rawValue }

        var title: String {
            switch self {
            case .high: return "Высокое"
            case .medium: return "Среднее"
            }
        }

        var bitrate: Int {
            switch self {
            case .high: return 320
            case .medium: return 192
            }
        }
    }

    static let shared = AppSettingsStore()

    @Published var theme: Theme {
        didSet { defaults.set(theme.rawValue, forKey: Keys.theme) }
    }

    @Published var crossfadeEnabled: Bool {
        didSet { defaults.set(crossfadeEnabled, forKey: Keys.crossfade) }
    }

    @Published var audioQuality: AudioQuality {
        didSet { defaults.set(audioQuality.rawValue, forKey: Keys.quality) }
    }

    /// Заглушка: напоминание слушать пока не реализовано.
    @Published var listeningReminder: Bool {
        didSet { defaults.set(listeningReminder, forKey: Keys.reminder) }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let theme = "settings.theme"
        static let crossfade = "settings.crossfade"
        static let quality = "settings.quality"
        static let reminder = "settings.reminder"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        theme = Theme(rawValue: defaults.string(forKey: Keys.theme) ?? "") ?? .dark
        crossfadeEnabled = defaults.bool(forKey: Keys.crossfade)
        audioQuality = AudioQuality(rawValue: defaults.string(forKey: Keys.quality) ?? "") ?? .high
        listeningReminder = defaults.bool(forKey: Keys.reminder)
    }

    var colorScheme: ColorScheme? { theme.colorScheme }
    var bitrate: Int { audioQuality.bitrate }
}