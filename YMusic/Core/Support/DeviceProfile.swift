import Combine
import Foundation
import OSLog

/// Класс устройства по `hw.machine`. Не `UIDevice`: нужен именно номер модели.
enum DeviceTier: String, Sendable {
    case lowTier
    case midTier
    case highTier

    var title: String {
        switch self {
        case .lowTier: return "Эконом"
        case .midTier: return "Средний"
        case .highTier: return "Максимум"
        }
    }
}

/// Ручной выбор режима производительности.
enum PerformanceMode: String, CaseIterable, Identifiable, Sendable {
    case auto
    case maximum
    case eco

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Авто"
        case .maximum: return "Максимум"
        case .eco: return "Эконом"
        }
    }
}

/// Единая точка «сколько эффектов тянет это железо».
///
/// Tier считается по идентификатору модели: iPhone 11 и старше — low,
/// iPhone 12–13 — mid, iPhone 14+ — high. Low Power Mode и нагрев
/// принудительно опускают профиль в low, чтобы телефон остыл.
///
/// Не `@MainActor`: профиль читают и Canvas-рендеры открыток, которые
/// работают вне основного потока. Публикации идут только с main (очередь
/// уведомлений задана явно), поэтому гонок нет.
final class DeviceProfile: ObservableObject {
    static let shared = DeviceProfile()

    static let powerNotification = Notification.Name.NSProcessInfoPowerStateDidChange

    @Published private(set) var deviceTier: DeviceTier
    @Published private(set) var currentProfile: DeviceTier
    @Published private(set) var thermalState: ProcessInfo.ThermalState
    @Published private(set) var lowPowerEnabled: Bool
    @Published private(set) var shouldPauseForHeat = false
    @Published var isHeatNoticeDismissed = false

    /// Ручной override. `.auto` — по железу и текущим условиям.
    @Published var performanceMode: PerformanceMode {
        didSet {
            defaults.set(performanceMode.rawValue, forKey: Self.modeKey)
            recompute()
        }
    }

    let machineIdentifier: String
    let machineLabel: String

    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.example.ymusic", category: "DeviceProfile")
    private var observers: [NSObjectProtocol] = []

    private static let modeKey = "performanceMode"

    init(defaults: UserDefaults = .standard) {
        let machine = Self.machineIdentifier()
        let major = Self.majorVersion(from: machine)
        let tier = Self.tier(for: major)

        let storedMode = defaults.string(forKey: Self.modeKey)
            .flatMap(PerformanceMode.init(rawValue:)) ?? .auto

        self.defaults = defaults
        self.machineIdentifier = machine
        self.machineLabel = Self.label(for: major)
        self.deviceTier = tier
        self.performanceMode = storedMode
        self.thermalState = ProcessInfo.processInfo.thermalState
        self.lowPowerEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        self.currentProfile = tier

        Self.applyFeatureDefaults(tier: tier, defaults: defaults)
        recompute()
        observeEnvironment()
    }

    deinit {
        let center = NotificationCenter.default
        for observer in observers {
            center.removeObserver(observer)
        }
    }

    // MARK: - Производные флаги

    /// Нагрев: анимации и тяжёлые эффекты замораживаются в любом режиме.
    var shouldFreezeVisuals: Bool {
        thermalState == .serious || thermalState == .critical
    }

    var isEco: Bool {
        performanceMode == .eco
    }

    /// Слабый профиль: эконом-режим, старое железо или перегрев.
    var isLowTier: Bool {
        currentProfile == .lowTier
    }

    /// Фон без пятен и без дрейфа: один градиент.
    var usesLightBackground: Bool {
        isLowTier || isEco || shouldFreezeVisuals
    }

    /// Живые анимации (частицы, спектр, винил) разрешены.
    var allowsAnimatedVisuals: Bool {
        !isEco && !shouldFreezeVisuals
    }

    /// FPS для Canvas-визуализатора.
    var visualizerFrameRate: Double {
        isLowTier ? 12 : 24
    }

    /// Сколько полос рисуем в спектре.
    var spectrumBarCount: Int {
        isLowTier ? 32 : 64
    }

    /// Сколько бинов формы волны просим у анализатора и рисуем.
    var waveformBinCount: Int {
        isLowTier ? 100 : 200
    }

    /// Частота вращения винила.
    var vinylFrameRate: Double {
        isLowTier ? 15 : 20
    }

    /// Спектр (FFT) считаем только на среднем и высоком профиле.
    var allowsSpectrumAnalysis: Bool {
        currentProfile != .lowTier && !isEco
    }

    /// Текст для настроек: «Авто (iPhone 11, эконом)».
    var statusText: String {
        "\(performanceMode.title) (\(machineLabel), \(currentProfile.title.lowercased()))"
    }

    // MARK: - Обновление

    func recompute() {
        let thermal = ProcessInfo.processInfo.thermalState
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        thermalState = thermal
        lowPowerEnabled = lowPower

        let base: DeviceTier
        switch performanceMode {
        case .eco:
            base = .lowTier
        case .maximum:
            base = deviceTier
        case .auto:
            base = (thermal == .serious || thermal == .critical || lowPower)
                ? .lowTier
                : deviceTier
        }

        if currentProfile != base {
            currentProfile = base
        }

        let pause = thermal == .critical
        if shouldPauseForHeat != pause {
            shouldPauseForHeat = pause
        }

        if !shouldFreezeVisuals {
            isHeatNoticeDismissed = false
        }
    }

    private func observeEnvironment() {
        let center = NotificationCenter.default
        let power = center.addObserver(
            forName: Self.powerNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.recompute()
        }

        let thermal = center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.recompute()
        }

        observers = [power, thermal]
    }

    // MARK: - Определение железа

    private static func machineIdentifier() -> String {
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else {
            return ""
        }

        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &buffer, &size, nil, 0) == 0 else {
            return ""
        }

        return String(cString: buffer)
    }

    private static func majorVersion(from machine: String) -> Int? {
        guard machine.hasPrefix("iPhone") else { return nil }
        let rest = machine.dropFirst("iPhone".count)
        let head = rest.split(separator: ",").first ?? Substring(rest)
        return Int(head)
    }

    private static func tier(for major: Int?) -> DeviceTier {
        guard let major else { return .lowTier }
        if major >= 16 { return .highTier }
        if major >= 14 { return .midTier }
        return .lowTier
    }

    private static func label(for major: Int?) -> String {
        guard let major else { return "симулятор" }
        switch major {
        case 11: return "iPhone X"
        case 12: return "iPhone 11"
        case 13: return "iPhone 11 Pro"
        case 14: return "iPhone 12"
        case 15: return "iPhone 13"
        case 16: return "iPhone 14"
        case 17: return "iPhone 15"
        default: return "iPhone"
        }
    }

    /// Дефолты фич зависят от класса устройства, но только при первом запуске:
    /// уже сохранённый выбор пользователя не перезаписываем.
    private static func applyFeatureDefaults(tier: DeviceTier, defaults: UserDefaults) {
        if defaults.object(forKey: "beatHapticsEnabled") == nil {
            defaults.set(tier != .lowTier, forKey: "beatHapticsEnabled")
        }
        if defaults.object(forKey: "autoDJEnabled") == nil {
            defaults.set(tier != .lowTier, forKey: "autoDJEnabled")
        }
        if defaults.object(forKey: "useRealSpectrum") == nil {
            defaults.set(tier != .lowTier, forKey: "useRealSpectrum")
        }
    }
}