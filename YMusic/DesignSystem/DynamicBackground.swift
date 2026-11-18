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
        .onAppear { isDrifting = true }
    }

    // MARK: - Слои

    private var backgroundLayers: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.03, green: 0.03, blue: 0.05),
                    Color(red: 0.05, green: 0.04, blue: 0.08)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            Circle()
                .fill(palette.primary.color)
                .frame(width: 540, height: 540)
                .blur(radius: 80)
                .opacity(0.85)
                .drawingGroup()
                .offset(x: -150, y: isDrifting ? -250 : -190)

            Circle()
                .fill(palette.secondary.color)
                .frame(width: 480, height: 480)
                .blur(radius: 90)
                .opacity(0.7)
                .drawingGroup()
                .offset(x: 170, y: isDrifting ? 360 : 290)

            // Скрим: гарантирует контраст текста даже при светлой обложке,
            // независимо от того, что делает материал.
            LinearGradient(
                colors: [Color.black.opacity(0.10), Color.black.opacity(0.48)],
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
