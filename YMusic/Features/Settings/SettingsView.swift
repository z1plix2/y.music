import SwiftUI

/// Экран настроек: аккаунт, тема, воспроизведение, волна, уведомления, «о приложении».
///
/// Все значения хранятся на диске (`AppSettingsStore` и `WaveSettingsStore`),
/// поэтому после перезапуска приложение выглядит так, как его оставили.
/// Экран открывается листом, а не пушем: в приложении нет `NavigationView`.
struct SettingsView: View {
    let account: Account
    let onClose: () -> Void

    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var waveSession: WaveSessionController
    @EnvironmentObject private var settings: AppSettingsStore
    @Environment(\.contentTone) private var tone

    @State private var showSignOutConfirm = false
    @State private var infoSheet: SettingsInfoSheet?

    /// Настройка живёт в `UserDefaults`, а не в `AppSettingsStore`: её читает
    /// `AudioPlayer` на старте трека, синхронизация через published-объект
    /// здесь только добавила бы связность.
    @AppStorage("beatHapticsEnabled") private var beatHapticsEnabled = false
    @AppStorage("beatHapticsWarningShown") private var beatHapticsWarningShown = false
    @AppStorage("useWaveformScrubber") private var useWaveformScrubber = true
    @AppStorage("useRealSpectrum") private var useRealSpectrum = true
    @AppStorage("autoDJEnabled") private var autoDJEnabled = true
    @State private var showBeatHapticsAlert = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                GlassScreenHeader(title: "Настройки", onClose: onClose)

                accountSection
                appearanceSection
                playbackSection
                waveSection
                notificationsSection
                aboutSection

                GlassButton(
                    "Выйти из аккаунта",
                    systemImage: "rectangle.portrait.and.arrow.right",
                    fullWidth: true
                ) {
                    Haptics.light()
                    showSignOutConfirm = true
                }
                .padding(.top, 4)

                Text("Сделано с ❤️ для iOS 15.3")
                    .font(.caption2)
                    .foregroundStyle(tone.tertiary)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 48)
        }
        .background(settingsBackground)
        .confirmationDialog(
            "Выйти из аккаунта?",
            isPresented: $showSignOutConfirm,
            titleVisibility: .visible
        ) {
            Button("Выйти", role: .destructive) { signOut() }
            Button("Отмена", role: .cancel) { }
        } message: {
            Text("Очередь и загруженный каталог будут очищены. Войти можно снова в любой момент.")
        }
        .sheet(item: $infoSheet) { sheet in
            switch sheet {
            case .whatsNew:
                SettingsTextSheet(
                    title: "Что нового",
                    onClose: { infoSheet = nil }
                ) {
                    changelog
                }
            case .credits:
                SettingsTextSheet(
                    title: "Кредиты",
                    onClose: { infoSheet = nil }
                ) {
                    credits
                }
            }
        }
        .alert("Вибрирует в такт", isPresented: $showBeatHapticsAlert) {
            Button("Включить") {
                beatHapticsWarningShown = true
                beatHapticsEnabled = true
                player.updateBeatHapticsPreference()
            }
            Button("Отмена", role: .cancel) { }
        } message: {
            Text("Телефон будет вибрировать в такт музыке. Работает только на iPhone с Taptic Engine.")
        }
        .onChange(of: beatHapticsEnabled) { _ in
            player.updateBeatHapticsPreference()
        }
        .onChange(of: autoDJEnabled) { _ in
            player.refreshAutoDJPreference()
        }
    }

    // MARK: - Фон

    /// Свой фон, чтобы экран не зависел от текущей обложки.
    private var settingsBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.07, green: 0.05, blue: 0.12),
                    Color(red: 0.03, green: 0.03, blue: 0.06)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 0.92, green: 0.16, blue: 0.22).opacity(0.28),
                            .clear
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 260
                    )
                )
                .frame(width: 520, height: 520)
                .offset(x: -140, y: -300)
                .blur(radius: 40)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Аккаунт

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            GlassSectionHeader("Аккаунт")

            GlassCard(cornerRadius: 22, padding: 16) {
                HStack(spacing: 14) {
                    accountAvatar

                    VStack(alignment: .leading, spacing: 3) {
                        Text(account.title)
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(tone.primary)
                            .lineLimit(1)

                        if let login = account.login, !login.isEmpty {
                            Text("@\(login)")
                                .font(.footnote)
                                .foregroundStyle(tone.secondary)
                        }

                        HStack(spacing: 6) {
                            Text(account.hasPlus ? "Yandex Plus" : "Без Plus")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(tone.tertiary)

                            Text("·")
                                .font(.caption2)
                                .foregroundStyle(tone.tertiary)

                            Text("id \(account.uid)")
                                .font(.caption2)
                                .foregroundStyle(tone.tertiary)
                        }
                    }

                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var accountAvatar: some View {
        Text(accountInitial)
            .font(.system(size: 22, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 54, height: 54)
            .background {
                Circle().fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.99, green: 0.45, blue: 0.12),
                            Color(red: 0.86, green: 0.10, blue: 0.24)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            }
            .overlay { Circle().strokeBorder(Color.white.opacity(0.28), lineWidth: 1) }
            .accessibilityHidden(true)
    }

    private var accountInitial: String {
        let source = account.displayName ?? account.fullName ?? account.login ?? "Y"
        let first = source.first.map(String.init) ?? "Y"
        return first.uppercased()
    }

    // MARK: - Внешний вид

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            GlassSectionHeader(
                "Внешний вид",
                subtitle: "Тема сохраняется между запусками"
            )

            GlassCard(cornerRadius: 22, padding: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    rowTitle("Тема", subtitle: "Светлая, тёмная или как в системе")

                    Picker("Тема", selection: $settings.theme) {
                        ForEach(AppSettingsStore.Theme.allCases) { theme in
                            Text(theme.title).tag(theme)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
    }

    // MARK: - Воспроизведение

    private var playbackSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            GlassSectionHeader("Воспроизведение")

            GlassCard(cornerRadius: 22, padding: 16) {
                VStack(alignment: .leading, spacing: 16) {
                    toggleRow(
                        "Кроссфейд между треками",
                        subtitle: "Плавное затухание при переключении",
                        isOn: $settings.crossfadeEnabled
                    )

                    Divider().overlay(tone.border.opacity(0.12))

                    toggleRow(
                        "Вибрирует в такт музыке",
                        subtitle: BeatHapticsSupport.isSupported
                            ? "Тактильный бит: kick, snare, hi-hat"
                            : "Не поддерживается на этом устройстве",
                        isOn: beatHapticsBinding,
                        isEnabled: BeatHapticsSupport.isSupported
                    )

                    Divider().overlay(tone.border.opacity(0.12))

                    rowTitle("Качество аудио", subtitle: "Битрейт стрима с сервера")

                    Picker("Качество аудио", selection: $settings.audioQuality) {
                        ForEach(AppSettingsStore.AudioQuality.allCases) { quality in
                            Text("\(quality.title) · \(quality.bitrate)").tag(quality)
                        }
                    }
                    .pickerStyle(.segmented)

                    Divider().overlay(tone.border.opacity(0.12))

                    toggleRow(
                        "Форма волны при скраббинге",
                        subtitle: "Столбики вместо слайдера",
                        isOn: $useWaveformScrubber
                    )

                    Divider().overlay(tone.border.opacity(0.12))

                    toggleRow(
                        "Спектр-визуализатор",
                        subtitle: "Реальный FFT вместо частиц",
                        isOn: $useRealSpectrum
                    )

                    Divider().overlay(tone.border.opacity(0.12))

                    toggleRow(
                        "Auto-DJ: плавный переход",
                        subtitle: "Затухание и разгон на стыке треков",
                        isOn: $autoDJEnabled
                    )
                }
            }
        }
    }

    // MARK: - Волна

    private var waveSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            GlassSectionHeader(
                "Моя волна",
                subtitle: "Те же настройки, что на главной"
            )

            GlassCard(cornerRadius: 22, padding: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        waveChip("Только новое", isOn: waveSession.settings.onlyNew) {
                            updateWave { $0.onlyNew.toggle() }
                        }

                        waveChip("По-русски", isOn: waveSession.settings.russian) {
                            updateWave { $0.russian.toggle() }
                        }
                    }

                    HStack(spacing: 8) {
                        waveChip("Спокойное", isOn: waveSession.settings.mood == .calm) {
                            updateWave { settings in
                                settings.mood = settings.mood == .calm ? nil : .calm
                            }
                        }

                        waveChip("Энергичное", isOn: waveSession.settings.mood == .energetic) {
                            updateWave { settings in
                                settings.mood = settings.mood == .energetic ? nil : .energetic
                            }
                        }
                    }

                    Text("Настройки применятся к следующей сессии волны.")
                        .font(.caption2)
                        .foregroundStyle(tone.tertiary)
                }
            }
        }
    }

    private func waveChip(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isOn ? tone.primary : tone.secondary)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background {
                    Capsule()
                        .fill(isOn ? Color.white.opacity(0.18) : Color.white.opacity(0.06))
                }
                .overlay {
                    Capsule()
                        .strokeBorder(
                            isOn ? Color.white.opacity(0.35) : Color.white.opacity(0.12),
                            lineWidth: 1
                        )
                }
        }
        .buttonStyle(PressableStyle(scale: 0.95))
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityLabel(title)
        .accessibilityHint(isOn ? "Выключить" : "Включить")
    }

    private func updateWave(_ change: (inout WaveSettings) -> Void) {
        var value = waveSession.settings
        change(&value)
        waveSession.settings = value
    }

    // MARK: - Уведомления

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            GlassSectionHeader("Уведомления")

            GlassCard(cornerRadius: 22, padding: 16) {
                HStack(spacing: 12) {
                    toggleRow(
                        "Напоминание слушать",
                        subtitle: "Скоро",
                        isOn: $settings.listeningReminder,
                        isEnabled: false
                    )
                }
            }
        }
    }

    // MARK: - О приложении

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            GlassSectionHeader("О приложении")

            GlassCard(cornerRadius: 22, padding: 16) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        rowTitle("Версия", subtitle: nil)

                        Spacer(minLength: 8)

                        Text(versionText)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(tone.secondary)
                    }

                    Divider().overlay(tone.border.opacity(0.12))

                    aboutButton("Что нового", systemImage: "sparkles") {
                        infoSheet = .whatsNew
                    }

                    Divider().overlay(tone.border.opacity(0.12))

                    aboutButton("Кредиты", systemImage: "heart") {
                        infoSheet = .credits
                    }
                }
            }
        }
    }

    private var versionText: String {
        "\(AppInfo.version) (\(AppInfo.build))"
    }

    private func aboutButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 22)

                Text(title)
                    .font(.system(size: 15, weight: .medium))

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tone.tertiary)
            }
            .foregroundStyle(tone.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.99))
    }

    // MARK: - Куски

    private func rowTitle(_ title: String, subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tone.primary)

            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(tone.tertiary)
            }
        }
    }

    private func toggleRow(
        _ title: String,
        subtitle: String?,
        isOn: Binding<Bool>,
        isEnabled: Bool = true
    ) -> some View {
        Toggle(isOn: isOn) {
            rowTitle(title, subtitle: subtitle)
        }
        .tint(Color(red: 0.92, green: 0.18, blue: 0.24))
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.55)
    }

    // MARK: - Выход

    /// Первое включение показывает предупреждение, дальше переключатель
    /// работает обычным `Binding`.
    private var beatHapticsBinding: Binding<Bool> {
        Binding(
            get: { beatHapticsEnabled },
            set: { newValue in
                if newValue, !beatHapticsWarningShown {
                    showBeatHapticsAlert = true
                    return
                }
                beatHapticsEnabled = newValue
            }
        )
    }

    private func signOut() {
        onClose()
        player.resetForSignOut()

        Task { @MainActor in
            await auth.signOut()
        }
    }

    // MARK: - Тексты

    private var changelog: some View {
        VStack(alignment: .leading, spacing: 18) {
            changelogRow(
                version: "0.1.0",
                items: [
                    "Моя волна с настройками и бесконечной лентой",
                    "Шазам: распознавание трека вокруг",
                    "Открытки: картинка и видео для соцсетей",
                    "Виджет на домашний экран с прогрессом",
                    "Статистика прослушивания и стрики"
                ]
            )
        }
    }

    private func changelogRow(version: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(version)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(tone.secondary)

            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(tone.tertiary)
                        .frame(width: 4, height: 4)
                        .padding(.top, 7)

                    Text(item)
                        .font(.footnote)
                        .foregroundStyle(tone.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var credits: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("YMusic — неофициальный клиент Яндекс Музыки, собранный на SwiftUI без сторонних библиотек.")
                .font(.footnote)
                .foregroundStyle(tone.primary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                creditLine("Музыка и API", value: "Яндекс")
                creditLine("Шазам", value: "ShazamKit")
                creditLine("Иконки", value: "SF Symbols")
            }

            Link(destination: URL(string: "https://github.com/z1plix2/y.music") ?? URL(fileURLWithPath: "/")) {
                HStack(spacing: 8) {
                    Image(systemName: "link")
                    Text("github.com/z1plix2/y.music")
                        .lineLimit(1)
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(tone.primary)
            }

            Text("Сделано с ❤️")
                .font(.footnote)
                .foregroundStyle(tone.secondary)
        }
    }

    private func creditLine(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(tone.secondary)

            Spacer(minLength: 8)

            Text(value)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(tone.primary)
        }
    }
}

// MARK: - Вложенные листы

private enum SettingsInfoSheet: String, Identifiable {
    case whatsNew
    case credits

    var id: String { rawValue }
}

/// Простой лист с заголовком и произвольным текстом: «Что нового» и «Кредиты».
private struct SettingsTextSheet<Content: View>: View {
    let title: String
    let onClose: () -> Void
    let content: Content

    @Environment(\.contentTone) private var tone

    init(title: String, onClose: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.title = title
        self.onClose = onClose
        self.content = content()
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                GlassScreenHeader(title: title, onClose: onClose)

                GlassCard(cornerRadius: 22, padding: 18) {
                    content
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 40)
        }
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.07, green: 0.05, blue: 0.12),
                    Color(red: 0.03, green: 0.03, blue: 0.06)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
        .environment(\.contentTone, .light)
    }
}