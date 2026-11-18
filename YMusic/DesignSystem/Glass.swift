import SwiftUI

// MARK: - Тон контента

/// Цвет текста/иконок на стекле. Считается из яркости фона, а не угадывается:
/// `DynamicBackground` кладёт значение в environment.
enum ContentTone: Equatable, Sendable {
    case light
    case dark

    var primary: Color { self == .light ? .white : Color(white: 0.08) }
    var secondary: Color { primary.opacity(0.66) }
    var tertiary: Color { primary.opacity(0.42) }
    var border: Color { self == .light ? .white : .black }
}

private struct ContentToneKey: EnvironmentKey {
    static let defaultValue: ContentTone = .light
}

extension EnvironmentValues {
    var contentTone: ContentTone {
        get { self[ContentToneKey.self] }
        set { self[ContentToneKey.self] = newValue }
    }
}

// MARK: - Подложка стекла

/// Затемняющая (или подсвечивающая) плёнка поверх материала.
/// Без неё `.ultraThinMaterial` на светлой обложке даёт нечитаемый текст.
struct GlassBackgroundOverlay: View {
    @Environment(\.contentTone) private var tone
    @Environment(\.appTheme) private var theme

    var body: some View {
        if theme.cardStyle == .glass {
            LinearGradient(
                colors: tone == .light
                    ? [Color.black.opacity(0.14), Color.black.opacity(0.34)]
                    : [Color.white.opacity(0.55), Color.white.opacity(0.32)],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
        } else {
            theme.palette.surfaceBase
        }
    }
}

// MARK: - Панель

struct GlassPanel: ViewModifier {
    var cornerRadius: CGFloat = 28
    var material: Material = .thinMaterial

    @Environment(\.appTheme) private var theme

    func body(content: Content) -> some View {
        let radius = cornerRadius * theme.cornerRadiusScale
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

        content
            .background { panelBackground(shape) }
            .clipShape(shape)
            .overlay { panelBorder(shape) }
            .shadow(
                color: theme.cardStyle == .glass ? .black.opacity(0.28) : .clear,
                radius: 20,
                x: 0,
                y: 14
            )
    }

    @ViewBuilder
    private func panelBackground(_ shape: RoundedRectangle) -> some View {
        switch theme.cardStyle {
        case .glass:
            shape
                .fill(material)
                .overlay {
                    GlassBackgroundOverlay()
                        .clipShape(shape)
                }
        case .flat, .solid:
            shape.fill(theme.palette.surfaceBase)
        }
    }

    @ViewBuilder
    private func panelBorder(_ shape: RoundedRectangle) -> some View {
        switch theme.cardStyle {
        case .glass:
            shape.strokeBorder(
                LinearGradient(
                    colors: [.white.opacity(0.35), .white.opacity(0.04)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
        case .flat, .solid:
            shape.strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
        }
    }
}

extension View {
    func glassPanel(cornerRadius: CGFloat = 28, material: Material = .thinMaterial) -> some View {
        modifier(GlassPanel(cornerRadius: cornerRadius, material: material))
    }
}

// MARK: - Карточка

struct GlassCard<Content: View>: View {
    private let cornerRadius: CGFloat
    private let padding: CGFloat
    private let content: Content

    init(cornerRadius: CGFloat = 28, padding: CGFloat = 18, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassPanel(cornerRadius: cornerRadius)
    }
}

// MARK: - Отклик кнопок

struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Кнопка

struct GlassButton: View {
    enum Prominence {
        case regular
        case prominent
    }

    private let title: String
    private let systemImage: String?
    private let prominence: Prominence
    private let isEnabled: Bool
    private let fullWidth: Bool
    private let action: () -> Void

    @Environment(\.contentTone) private var tone
    @Environment(\.appTheme) private var theme

    init(
        _ title: String,
        systemImage: String? = nil,
        prominence: Prominence = .regular,
        isEnabled: Bool = true,
        fullWidth: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.prominence = prominence
        self.isEnabled = isEnabled
        self.fullWidth = fullWidth
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 20)
            .frame(height: 46)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background { backgroundView }
            .overlay { borderView }
            .clipShape(Capsule())
            .shadow(color: shadowColor, radius: 14, x: 0, y: 8)
        }
        .buttonStyle(PressableStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
    }

    private var foregroundColor: Color {
        guard prominence == .prominent else { return tone.primary }
        // На жёлтом акценте белый текст нечитаем — Яндекс-тема просит чёрный.
        return theme == .yandex ? Color.black.opacity(0.86) : .white
    }

    @ViewBuilder
    private var backgroundView: some View {
        if prominence == .prominent {
            if theme.useGradientButtons {
                Capsule().fill(
                    LinearGradient(
                        colors: [
                            theme.palette.primaryAccent,
                            theme.palette.secondaryAccent
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            } else {
                Capsule().fill(theme.palette.primaryAccent)
            }
        } else if theme.cardStyle == .glass {
            Capsule()
                .fill(.thinMaterial)
                .overlay {
                    Capsule().fill(Color.black.opacity(0.22))
                }
        } else {
            Capsule().fill(theme.palette.surfaceBase)
        }
    }

    @ViewBuilder
    private var borderView: some View {
        if prominence == .prominent {
            Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
        } else if theme.cardStyle == .glass {
            Capsule().strokeBorder(
                LinearGradient(
                    colors: [.white.opacity(0.30), .white.opacity(0.04)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
        } else {
            Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        }
    }

    private var shadowColor: Color {
        guard theme.cardStyle == .glass else { return .clear }
        return prominence == .prominent
            ? theme.palette.primaryAccent.opacity(0.25)
            : Color.black.opacity(0.25)
    }
}

// MARK: - Иконочная кнопка

struct GlassIconButton: View {
    private let systemImage: String
    private let label: String
    private let action: () -> Void

    @Environment(\.contentTone) private var tone
    @Environment(\.appTheme) private var theme

    init(_ systemImage: String, label: String, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tone.primary)
                .frame(width: 40, height: 40)
                .background {
                    if theme.cardStyle == .glass {
                        Circle()
                            .fill(.ultraThinMaterial)
                            .overlay { Circle().fill(Color.black.opacity(0.14)) }
                    } else {
                        Circle().fill(theme.palette.surfaceBase)
                    }
                }
                .overlay {
                    Circle().strokeBorder(
                        Color.white.opacity(theme.cardStyle == .glass ? 0.18 : 0.10),
                        lineWidth: 1
                    )
                }
        }
        .buttonStyle(PressableStyle(scale: 0.92))
        .accessibilityLabel(label)
    }
}

// MARK: - Заголовок секции

struct GlassSectionHeader: View {
    private let title: String
    private let subtitle: String?
    private let trailingTitle: String?
    private let trailingAction: (() -> Void)?

    @Environment(\.contentTone) private var tone
    @Environment(\.appTheme) private var theme

    init(
        _ title: String,
        subtitle: String? = nil,
        trailingTitle: String? = nil,
        trailingAction: (() -> Void)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.trailingTitle = trailingTitle
        self.trailingAction = trailingAction
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .foregroundStyle(tone.primary)

                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(tone.tertiary)
                }
            }

            Spacer(minLength: 8)

            if let trailingTitle, let trailingAction {
                Button(action: trailingAction) {
                    Text(trailingTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tone.secondary)
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background {
                            if theme.cardStyle == .glass {
                                Capsule().fill(.ultraThinMaterial)
                            } else {
                                Capsule().fill(theme.palette.surfaceBase)
                            }
                        }
                        .overlay(
                            Capsule().strokeBorder(
                                Color.white.opacity(theme.cardStyle == .glass ? 0.14 : 0.10),
                                lineWidth: 1
                            )
                        )
                }
                .buttonStyle(PressableStyle(scale: 0.94))
            }
        }
    }
}

// MARK: - Чип

struct GlassChip: View {
    private let title: String
    private let systemImage: String?

    @Environment(\.contentTone) private var tone
    @Environment(\.appTheme) private var theme

    init(_ title: String, systemImage: String? = nil) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
            }
            Text(title)
                .font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(tone.secondary)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background {
            if theme.cardStyle == .glass {
                Capsule().fill(.ultraThinMaterial)
            } else {
                Capsule().fill(theme.palette.surfaceBase)
            }
        }
        .overlay(
            Capsule().strokeBorder(
                Color.white.opacity(theme.cardStyle == .glass ? 0.14 : 0.10),
                lineWidth: 1
            )
        )
    }
}

// MARK: - Тематические имена

/// Компоненты читают `\.appTheme`; старые имена сохранены, чтобы не
/// переписывать десятки call sites. Новый код может звать Theme*.
typealias ThemePanel = GlassPanel
typealias ThemeCard<Content: View> = GlassCard<Content>
typealias ThemeButton = GlassButton
typealias ThemeIconButton = GlassIconButton
typealias ThemeSectionHeader = GlassSectionHeader
typealias ThemeChip = GlassChip

// MARK: - Живой фон (экран входа)

/// Цветные пятна за стеклом. Используется на `LoginView`, где ещё нет
/// обложки для `DynamicBackground`.
struct LiquidBackdrop: View {
    /// `nil` — акцент берётся из текущей темы.
    var tint: Color?

    @Environment(\.appTheme) private var theme
    @State private var animate = false

    var body: some View {
        // `Color.clear` + `.background`: пятна с фиксированными размерами
        // не должны растягивать родительский ZStack шире экрана.
        Color.clear
            .background { layers }
            .ignoresSafeArea()
            .onAppear {
                guard theme.useDynamicBackground, !animate else { return }
                withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) {
                    animate = true
                }
            }
    }

    private var accent: Color { tint ?? theme.palette.primaryAccent }

    private var layers: some View {
        ZStack {
            LinearGradient(
                colors: theme.backgroundGradient,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if theme.useDynamicBackground {
                blob(accent, size: 360, x: animate ? 120 : -110, y: animate ? -220 : -60, opacity: 0.38)
                blob(theme.palette.secondaryAccent, size: 320,
                     x: animate ? -130 : 100, y: animate ? 180 : 320, opacity: 0.32)
                blob(Color(red: 0.10, green: 0.65, blue: 0.85), size: 260,
                     x: animate ? 90 : 20, y: animate ? 320 : 120, opacity: 0.21)
            }
        }
        .allowsHitTesting(false)
    }

    private func blob(_ color: Color, size: CGFloat, x: CGFloat, y: CGFloat, opacity: Double) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [color.opacity(opacity), color.opacity(0)],
                    center: .center,
                    startRadius: 0,
                    endRadius: size / 2
                )
            )
            .frame(width: size, height: size)
            .offset(x: x, y: y)
            .blur(radius: 40)
    }
}
