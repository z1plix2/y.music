import SwiftUI

/// Фон всего приложения: два размытых пятна цвета, извлечённого из обложки,
/// затемняющая плёнка и подсказка контентному слою, какого цвета текст.
///
/// `cacheKey` должен совпадать с ключом, под которым `ImageLoader` прогрел
/// палитру (обычно `url.absoluteString`), иначе будет второй сетевой запрос.
struct DynamicBackground<Content: View>: View {
    private let imageURL: URL?
    private let cacheKey: String
    private let fallback: ColorPalette
    private let content: Content

    @State private var palette: ColorPalette
    @State private var isDrifting = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appTheme) private var theme
    /// Тяжёлый фон (пятна + дрейф) живёт только на сильном железе.
    @ObservedObject private var device = DeviceProfile.shared

    init(
        imageURL: URL?,
        cacheKey: String,
        fallback: ColorPalette = .brand,
        @ViewBuilder content: () -> Content
    ) {
        self.imageURL = imageURL
        self.cacheKey = cacheKey
        self.fallback = fallback
        self.content = content()
        _palette = State(initialValue: fallback)
    }

    var body: some View {
        ZStack {
            // Прозрачный слой задаёт размер экрана, а пятна рисуются в его
            // background: у них фиксированные 540×540, и если положить их
            // прямым ребёнком ZStack, корень становится шире экрана —
            // контент обрезается слева и справа. Фон не должен участвовать
            // в расчёте layout.
            Color.clear
                .background { backgroundLayers }
                .ignoresSafeArea()

            content
        }
        .environment(\.contentTone, palette.contentTone)
        .task(id: cacheKey) { await loadPalette() }
        .onAppear { updateDrift() }
        .onDisappear { isDrifting = false }
        .onChange(of: scenePhase) { _ in updateDrift() }
        .onChange(of: device.usesLightBackground) { _ in updateDrift() }
        .onChange(of: theme) { _ in updateDrift() }
    }

    /// Дрейф пятен — бесконечная анимация. В фоне и когда экран ушёл
    /// с глаз, она не нужна: останавливаем, чтобы не жечь GPU вхолостую.
    private func updateDrift() {
        // На слабом профиле и при нагреве фон статичный: дрейф — это
        // бесконечная анимация двух больших blur-слоёв. Темы без живого
        // фона (minimal, amoled) тоже не анимируют ничего.
        let shouldDrift = scenePhase == .active
            && theme.useDynamicBackground
            && !device.usesLightBackground
        guard isDrifting != shouldDrift else { return }
        isDrifting = shouldDrift
    }

    // MARK: - Слои

    @ViewBuilder
    private var backgroundLayers: some View {
        if !theme.useDynamicBackground {
            plainBackground
        } else if device.usesLightBackground {
            lightBackground
        } else {
            fullBackground
        }
    }

    /// Без динамики: только градиент темы. Ни blur, ни пятен, ни анимаций.
    private var plainBackground: some View {
        LinearGradient(
            colors: theme.backgroundGradient,
            startPoint: .top,
            endPoint: .bottom
        )
        .allowsHitTesting(false)
    }

    /// Экономный вариант: один градиент вместо двух размытых кругов.
    private var lightBackground: some View {
        ZStack {
            LinearGradient(
                colors: theme.backgroundGradient,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            LinearGradient(
                colors: [Color.black.opacity(0.20), Color.black.opacity(0.65)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .allowsHitTesting(false)
    }

    private var fullBackground: some View {
        ZStack {
            LinearGradient(
                colors: theme.backgroundGradient,
                startPoint: .top,
                endPoint: .bottom
            )

            Circle()
                .fill(palette.primary.color)
                .overlay(Circle().fill(theme.palette.primaryAccent.opacity(0.35)))
                .frame(width: 540, height: 540)
                .blur(radius: 100)
                .opacity(0.50)
                .drawingGroup()
                .offset(x: -150, y: isDrifting ? -230 : -200)

            Circle()
                .fill(palette.secondary.color)
                .overlay(Circle().fill(theme.palette.secondaryAccent.opacity(0.30)))
                .frame(width: 480, height: 480)
                .blur(radius: 110)
                .opacity(0.40)
                .drawingGroup()
                .offset(x: 170, y: isDrifting ? 360 : 290)

            // Скрим: гарантирует контраст текста даже при светлой обложке,
            // независимо от того, что делает материал.
            LinearGradient(
                colors: [Color.black.opacity(0.20), Color.black.opacity(0.65)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .animation(.easeInOut(duration: 0.8), value: palette)
        .animation(
            .easeInOut(duration: 14).repeatForever(autoreverses: true),
            value: isDrifting
        )
        .allowsHitTesting(false)
    }

    // MARK: - Загрузка

    private func loadPalette() async {
        guard let imageURL else {
            palette = fallback
            return
        }

        let extracted = await ColorExtractor.shared.palette(forKey: cacheKey, from: imageURL)
        guard !Task.isCancelled else { return }
        palette = extracted ?? fallback
    }
}
