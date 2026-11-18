import Combine
import SwiftUI
import UIKit

/// Визуальный стиль приложения.
///
/// Тема — это не только акцент: она решает, из чего собраны карточки
/// (стекло/плоскость/сплошной цвет), есть ли живой фон и насколько
/// «круглые» углы. Все компоненты дизайн-системы читают тему из
/// environment, поэтому переключение не требует пересоздания экранов.
enum AppTheme: String, CaseIterable, Codable, Identifiable, Sendable {
    case liquidGlass
    case minimal
    case yandex
    case amoledBlack
    case vinyl

    var id: String { rawValue }

    var title: String {
        switch self {
        case .liquidGlass: return "Стекло"
        case .minimal: return "Минимализм"
        case .yandex: return "Яндекс"
        case .amoledBlack: return "AMOLED"
        case .vinyl: return "Винил"
        }
    }

    var description: String {
        switch self {
        case .liquidGlass: return "Стекло с яркими акцентами"
        case .minimal: return "Минимализм как Apple Music"
        case .yandex: return "Классика Яндекса"
        case .amoledBlack: return "Чистый чёрный для OLED"
        case .vinyl: return "Всегда виниловый плеер"
        }
    }

    /// Короткая подпись для превью в настройках.
    var shortDescription: String {
        switch self {
        case .liquidGlass: return "Матовые карточки и живой фон"
        case .minimal: return "Плоские поверхности, синий акцент"
        case .yandex: return "Жёлтый акцент и стекло"
        case .amoledBlack: return "Чёрный фон, без размытий"
        case .vinyl: return "Тёплый коричневый, вертушка"
        }
    }

    var palette: ThemePalette {
        switch self {
        case .liquidGlass:
            return ThemePalette(
                primaryAccent: Color(red: 0.85, green: 0.20, blue: 0.30),
                secondaryAccent: Color(red: 0.72, green: 0.04, blue: 0.12),
                backgroundBase: Color(red: 0.05, green: 0.05, blue: 0.07),
                surfaceBase: Color.white.opacity(0.06)
            )
        case .minimal:
            return ThemePalette(
                primaryAccent: Color(red: 0.20, green: 0.55, blue: 0.95),
                secondaryAccent: Color(red: 0.10, green: 0.35, blue: 0.78),
                backgroundBase: Color(red: 0.03, green: 0.03, blue: 0.04),
                surfaceBase: Color.white.opacity(0.06)
            )
        case .yandex:
            return ThemePalette(
                primaryAccent: Color(red: 0.99, green: 0.82, blue: 0.16),
                secondaryAccent: Color(red: 0.95, green: 0.60, blue: 0.04),
                backgroundBase: Color(red: 0.04, green: 0.04, blue: 0.06),
                surfaceBase: Color.white.opacity(0.07)
            )
        case .amoledBlack:
            return ThemePalette(
                primaryAccent: Color(red: 0.95, green: 0.30, blue: 0.35),
                secondaryAccent: Color(red: 0.74, green: 0.15, blue: 0.20),
                backgroundBase: .black,
                surfaceBase: Color.white.opacity(0.025)
            )
        case .vinyl:
            return ThemePalette(
                primaryAccent: Color(red: 0.87, green: 0.42, blue: 0.20),
                secondaryAccent: Color(red: 0.55, green: 0.24, blue: 0.10),
                backgroundBase: Color(red: 0.12, green: 0.08, blue: 0.05),
                surfaceBase: Color(red: 0.24, green: 0.17, blue: 0.11).opacity(0.85)
            )
        }
    }

    var cardStyle: ThemeCardStyle {
        switch self {
        case .liquidGlass, .yandex, .vinyl: return .glass
        case .minimal, .amoledBlack: return .flat
        }
    }

    /// Материал карточки. `nil` — тема не использует размытие вовсе:
    /// так на слабом железе и на AMOLED не тратится GPU.
    var material: Material? {
        cardStyle == .glass ? .thinMaterial : nil
    }

    var useDynamicBackground: Bool {
        switch self {
        case .minimal, .amoledBlack: return false
        case .liquidGlass, .yandex, .vinyl: return true
        }
    }

    var useGradientButtons: Bool {
        switch self {
        case .liquidGlass, .yandex, .vinyl: return true
        case .minimal, .amoledBlack: return false
        }
    }

    var cornerRadiusScale: CGFloat {
        switch self {
        case .liquidGlass, .yandex: return 1.0
        case .minimal: return 0.8
        case .amoledBlack: return 0.9
        case .vinyl: return 1.1
        }
    }

    /// Фон приложения: градиент из двух близких оттенков темы.
    var backgroundGradient: [Color] {
        switch self {
        case .amoledBlack:
            return [.black, .black]
        case .minimal:
            return [
                Color(red: 0.04, green: 0.04, blue: 0.05),
                Color(red: 0.01, green: 0.01, blue: 0.02)
            ]
        case .yandex:
            return [
                Color(red: 0.05, green: 0.05, blue: 0.07),
                Color(red: 0.10, green: 0.08, blue: 0.03)
            ]
        case .vinyl:
            return [
                Color(red: 0.16, green: 0.10, blue: 0.06),
                Color(red: 0.05, green: 0.03, blue: 0.02)
            ]
        case .liquidGlass:
            return [
                Color(red: 0.05, green: 0.05, blue: 0.07),
                Color(red: 0.07, green: 0.06, blue: 0.10)
            ]
        }
    }

    /// Все темы тёмные; системная настройка «Светлая» по-прежнему
    /// перекрывает это значение через `AppSettingsStore`.
    var prefersDark: Bool { true }

    /// Тема, в которой плеер по умолчанию открывается вертушкой.
    var prefersVinylPlayer: Bool { self == .vinyl }
}

struct ThemePalette {
    let primaryAccent: Color
    let secondaryAccent: Color
    let backgroundBase: Color
    let surfaceBase: Color

    /// Палитра для `DynamicBackground`: тема задаёт базовый тон, обложка
    /// только подкрашивает пятна.
    var colorPalette: ColorPalette {
        ColorPalette(
            primary: RGBColor(
                red: primaryAccent.components.red,
                green: primaryAccent.components.green,
                blue: primaryAccent.components.blue
            ),
            secondary: RGBColor(
                red: secondaryAccent.components.red,
                green: secondaryAccent.components.green,
                blue: secondaryAccent.components.blue
            )
        )
    }
}

enum ThemeCardStyle {
    case glass
    case flat
    case solid
}

// MARK: - Environment

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue: AppTheme = .liquidGlass
}

extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}

extension Notification.Name {
    /// Тема сменилась. Нужно экранам вне SwiftUI-иерархии (Splash, виджет).
    static let themeDidChange = Notification.Name("themeDidChange")
}

// MARK: - Извлечение компонент цвета

private extension Color {
    /// Достаёт sRGB-компоненты из SwiftUI `Color`, чтобы отдать их
    /// в `ColorPalette` (там хранятся числа, а не `Color`).
    var components: (red: Double, green: Double, blue: Double) {
        let uiColor = UIColor(self)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (Double(red), Double(green), Double(blue))
    }
}