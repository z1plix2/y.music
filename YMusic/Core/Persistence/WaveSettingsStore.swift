import Foundation

/// Настройки «Моей волны»: превращаются в сиды сессии радио.
///
/// Значения взяты из `MarshalX/yandex-music-api` (`docs/source/radio.md`,
/// «Сиды и волны»): `settingDiversity:discover`, `settingLanguage:russian`,
/// `mood:calm`, `mood:energetic`. Настроение взаимоисключающее — сервер
/// принимает один `mood:*`.
struct WaveSettings: Equatable, Sendable {
    enum Mood: String, Sendable {
        case calm
        case energetic
    }

    var onlyNew: Bool = false
    var russian: Bool = false
    var mood: Mood?

    /// Полный набор сидов: базовая волна + включённые настройки.
    var seeds: [String] {
        var result = ["user:onyourwave"]
        if onlyNew {
            result.append("settingDiversity:discover")
        }
        if russian {
            result.append("settingLanguage:russian")
        }
        if let mood {
            result.append("mood:\(mood.rawValue)")
        }
        return result
    }
}

/// Хранилище настроек волны в `UserDefaults`.
///
/// Четыре независимых ключа вместо JSON: набор маленький, а так значения
/// читаются без риска сломаться при добавлении нового чипа.
struct WaveSettingsStore {
    private static let onlyNewKey = "wave.onlyNew"
    private static let russianKey = "wave.russian"
    private static let moodKey = "wave.mood"

    private let defaults: UserDefaults
    /// Запись — на своей очереди: тап по чипу не должен ждать диск.
    private let queue = DispatchQueue(label: "com.example.ymusic.wave.settings", qos: .utility)

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> WaveSettings {
        WaveSettings(
            onlyNew: defaults.bool(forKey: Self.onlyNewKey),
            russian: defaults.bool(forKey: Self.russianKey),
            mood: defaults.string(forKey: Self.moodKey).flatMap(WaveSettings.Mood.init(rawValue:))
        )
    }

    func save(_ settings: WaveSettings) {
        queue.async {
            defaults.set(settings.onlyNew, forKey: Self.onlyNewKey)
            defaults.set(settings.russian, forKey: Self.russianKey)
            defaults.set(settings.mood?.rawValue, forKey: Self.moodKey)
        }
    }
}