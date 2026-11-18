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

    var body: some View {
        LinearGradient(
            colors: tone == .light
                ? [Color.black.opacity(0.14), Color.black.opacity(0.34)]
                : [Color.white.opacity(0.55), Color.white.opacity(0.32)],
            startPoint: .top,
            endPoint: .bottom
        )
        .allowsHitTesting(false)
    }
}

// MARK: - Панель

struct GlassPanel: ViewModifier {
    var cornerRadius: CGFloat = 28
    var material: Material = .ultraThinMaterial

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        content
            .background {
                shape
                    .fill(material)
                    .overlay {
                        GlassBackgroundOverlay()
                            .clipShape(shape)
                    }
            }
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.55), .white.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            }
            .shadow(color: .black.opacity(0.35), radius: 26, x: 0, y: 14)
    }
}

extension View {
    func glassPanel(cornerRadius: CGFloat = 28, material: Material = .ultraThinMaterial) -> some View {
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
        prominence == .prominent ? .white : tone.primary
    }

    @ViewBuilder
    private var backgroundView: some View {
        if prominence == .prominent {
            Capsule().fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.92, green: 0.18, blue: 0.24),
                        Color(red: 0.82, green: 0.08, blue: 0.16)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        } else {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay {
                    Capsule().fill(Color.black.opacity(0.14))
                }
        }
    }

    @ViewBuilder
    private var borderView: some View {
        if prominence == .prominent {
            Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
        } else {
            Capsule().strokeBorder(
                LinearGradient(
                    colors: [.white.opacity(0.45), .white.opacity(0.06)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
        }
    }

    private var shadowColor: Color {
        prominence == .prominent
            ? Color(red: 0.90, green: 0.15, blue: 0.20).opacity(0.35)
            : Color.black.opacity(0.25)
    }
}

// MARK: - Иконочная кнопка

struct GlassIconButton: View {
    private let systemImage: String
    private let label: String
    private let action: () -> Void

    @Environment(\.contentTone) private var tone

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
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay { Circle().fill(Color.black.opacity(0.14)) }
                }
                .overlay {
                    Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
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
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
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
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
    }
}

// MARK: - Живой фон (экран входа)

/// Цветные пятна за стеклом. Используется на `LoginView`, где ещё нет
/// обложки для `DynamicBackground`.
struct LiquidBackdrop: View {
    var tint: Color = Color(red: 0.92, green: 0.16, blue: 0.22)

    @State private var animate = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.04, blue: 0.07),
                    Color(red: 0.08, green: 0.06, blue: 0.14),
                    Color(red: 0.03, green: 0.03, blue: 0.06)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            blob(tint, size: 360, x: animate ? 120 : -110, y: animate ? -220 : -60, opacity: 0.55)
            blob(Color(red: 0.35, green: 0.25, blue: 0.95), size: 320,
                 x: animate ? -130 : 100, y: animate ? 180 : 320, opacity: 0.45)
            blob(Color(red: 0.10, green: 0.65, blue: 0.85), size: 260,
                 x: animate ? 90 : 20, y: animate ? 320 : 120, opacity: 0.3)
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) {
                animate = true
            }
        }
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
