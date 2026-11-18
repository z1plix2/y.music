import SwiftUI

/// Онбординг первого запуска: три экрана и вход.
///
/// Показывается один раз — флаг `hasSeenOnboarding` в `UserDefaults`.
/// После «Продолжить» на последнем экране открывается обычный `RootView`
/// с `LoginView`: онбординг не логинит сам, а только объясняет, что внутри.
struct OnboardingView: View {
    let onFinish: () -> Void

    @State private var page = 0
    @Environment(\.appTheme) private var theme

    private let pageCount = 3

    var body: some View {
        ZStack {
            LiquidBackdrop()

            VStack(spacing: 0) {
                topBar

                TabView(selection: $page) {
                    welcomePage.tag(0)
                    wavePage.tag(1)
                    featuresPage.tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                pageDots

                bottomBar
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 28)
            .frame(maxWidth: 520)
        }
        .environment(\.contentTone, .light)
    }

    // MARK: - Верх

    private var topBar: some View {
        HStack {
            Text("YMusic")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))

            Spacer(minLength: 0)

            Button {
                Haptics.selection()
                onFinish()
            } label: {
                Text("Пропустить")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.62))
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            }
            .buttonStyle(PressableStyle(scale: 0.94))
            .accessibilityLabel("Пропустить знакомство")
        }
    }

    // MARK: - Страницы

    private var welcomePage: some View {
        pageLayout {
            ZStack {
                RoundedRectangle(cornerRadius: 36, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                theme.palette.primaryAccent,
                                theme.palette.secondaryAccent
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 132, height: 132)
                    .shadow(color: theme.palette.primaryAccent.opacity(0.45), radius: 34, y: 16)

                Image(systemName: "waveform")
                    .font(.system(size: 54, weight: .semibold))
                    .foregroundStyle(theme == .yandex ? Color.black.opacity(0.8) : .white)
            }
        } title: {
            pageTitle("Добро пожаловать\nв YMusic")
        } subtitle: {
            pageSubtitle("Слушай свою музыку без лишнего.")
        }
    }

    private var wavePage: some View {
        pageLayout {
            GlassCard(cornerRadius: 28, padding: 18) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.35, green: 0.25, blue: 0.95),
                                        Color(red: 0.10, green: 0.65, blue: 0.85)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 54, height: 54)
                            .overlay {
                                Image(systemName: "music.note")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.9))
                            }

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Моя волна")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)

                            Text("Бесконечный поток")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.6))
                        }

                        Spacer(minLength: 0)
                    }

                    WaveVisualizer(isPlaying: page == 1, height: 96)
                        .frame(maxWidth: .infinity)

                    HStack(spacing: 8) {
                        GlassChip("Только новое", systemImage: "sparkles")
                        GlassChip("По-русски", systemImage: "globe")
                    }
                }
            }
            .environment(\.contentTone, .light)
            .padding(.horizontal, 4)
        } title: {
            pageTitle("Волна, которая\nне заканчивается")
        } subtitle: {
            pageSubtitle("Подбирается под тебя в реальном времени.")
        }
    }

    private var featuresPage: some View {
        pageLayout {
            VStack(spacing: 12) {
                featureTile(
                    systemImage: "waveform.badge.mic",
                    title: "Шазам",
                    subtitle: "Узнай трек вокруг",
                    colors: [
                        Color(red: 0.35, green: 0.25, blue: 0.95),
                        Color(red: 0.55, green: 0.15, blue: 0.75)
                    ]
                )

                featureTile(
                    systemImage: "rectangle.on.rectangle",
                    title: "Виджет",
                    subtitle: "Трек на домашнем экране",
                    colors: [
                        Color(red: 0.92, green: 0.32, blue: 0.16),
                        Color(red: 0.80, green: 0.10, blue: 0.30)
                    ]
                )

                featureTile(
                    systemImage: "flame",
                    title: "Стрики",
                    subtitle: "Слушай каждый день",
                    colors: [
                        Color(red: 0.99, green: 0.62, blue: 0.18),
                        Color(red: 0.92, green: 0.32, blue: 0.10)
                    ]
                )
            }
            .padding(.horizontal, 4)
        } title: {
            pageTitle("Больше, чем\nпросто плеер")
        } subtitle: {
            pageSubtitle("Шазам, виджеты, стрики — всё, чего нет у других.")
        }
    }

    private func featureTile(
        systemImage: String,
        title: String,
        subtitle: String,
        colors: [Color]
    ) -> some View {
        GlassCard(cornerRadius: 22, padding: 14) {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 48, height: 48)
                    .overlay {
                        Image(systemName: systemImage)
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(.white)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)

                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.62))
                }

                Spacer(minLength: 0)
            }
        }
        .environment(\.contentTone, .light)
    }

    // MARK: - Каркас страницы

    private func pageLayout<Illustration: View>(
        @ViewBuilder illustration: () -> Illustration,
        @ViewBuilder title: () -> some View,
        @ViewBuilder subtitle: () -> some View
    ) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 8)

            illustration()
                .frame(maxWidth: .infinity)

            Spacer(minLength: 34)

            title()
            subtitle()
                .padding(.top, 12)

            Spacer(minLength: 24)
        }
        .padding(.horizontal, 4)
    }

    private func pageTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 34, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func pageSubtitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.white.opacity(0.64))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
    }

    // MARK: - Низ

    private var pageDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<pageCount, id: \.self) { index in
                Capsule()
                    .fill(index == page ? Color.white : Color.white.opacity(0.24))
                    .frame(width: index == page ? 22 : 7, height: 7)
                    .animation(.easeInOut(duration: 0.22), value: page)
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 18)
        .accessibilityHidden(true)
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            GlassButton(
                page == pageCount - 1 ? "Войти через Яндекс" : "Продолжить",
                systemImage: page == pageCount - 1 ? "person.crop.circle" : "arrow.right",
                prominence: .prominent,
                fullWidth: true
            ) {
                Haptics.light()

                if page == pageCount - 1 {
                    onFinish()
                } else {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        page += 1
                    }
                }
            }

            Text("Продолжая, вы входите в свой аккаунт Яндекса")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.42))
                .frame(maxWidth: .infinity, alignment: .center)
                .opacity(page == pageCount - 1 ? 1 : 0)
        }
        .environment(\.contentTone, .light)
    }
}