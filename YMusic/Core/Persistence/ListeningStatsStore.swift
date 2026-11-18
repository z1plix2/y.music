import Combine
import Foundation
import OSLog

/// Статистика прослушивания: стрик по дням, суммарное время и счётчики
/// треков. Всё лежит в `UserDefaults` под ключами с `userID`, чтобы
/// переключение аккаунта не смешивало цифры.
///
/// Стор — синглтон: его читают и `AudioPlayer` (запись), и главная (чип),
/// и экран статистики. Поэтому вместо нескольких экземпляров одно
/// опубликованное состояние, а `configure(userID:)` переключает профиль.
@MainActor
final class ListeningStatsStore: ObservableObject {
    struct Snapshot: Equatable {
        var currentStreak: Int = 0
        var longestStreak: Int = 0
        /// `yyyy-MM-dd` последнего дня, когда что-то играло.
        var lastListenedDay: String = ""
        var totalListeningSeconds: Double = 0
        /// `trackID` → сколько раз начинали играть.
        var playCountsByTrackID: [String: Int] = [:]
    }

    static let shared = ListeningStatsStore()

    @Published private(set) var snapshot = Snapshot()

    /// Точность времени: тики плеера идут раз в 0.5 с, поэтому и здесь шаг 0.5.
    static let tickSeconds: Double = 0.5

    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.example.ymusic", category: "ListeningStats")
    /// Запись четырёх ключей + JSON — в фоне, чтобы тик плеера не ждал диск.
    private let persistQueue = DispatchQueue(
        label: "com.example.ymusic.listening-stats",
        qos: .utility
    )

    private var userID: Int?
    private var lastPersist = Date.distantPast
    /// Накопленное, но ещё не опубликованное время: `@Published` на каждом
    /// тике перерисовывал бы главную каждые 0.5 с.
    private var pendingSeconds: Double = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Профиль

    func configure(userID: Int) {
        guard self.userID != userID else { return }
        self.userID = userID
        pendingSeconds = 0
        lastPersist = Date.distantPast
        snapshot = load(userID: userID)
    }

    /// Сброс при выходе из аккаунта: статистика остаётся на диске, но
    /// в памяти больше не висит чужой профиль.
    func detach() {
        userID = nil
        snapshot = Snapshot()
    }

    // MARK: - Запись

    /// Начало трека: обновляет стрик и счётчик проигрываний.
    func recordStart(_ track: Track) {
        guard userID != nil else { return }

        var updated = snapshot
        let today = Self.dayKey(for: Date())

        if updated.lastListenedDay != today {
            let yesterday = Self.dayKey(
                for: Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
            )

            if updated.lastListenedDay == yesterday {
                updated.currentStreak += 1
            } else {
                updated.currentStreak = 1
            }

            updated.lastListenedDay = today
            updated.longestStreak = max(updated.longestStreak, updated.currentStreak)
        }

        let key = String(track.id)
        updated.playCountsByTrackID[key, default: 0] += 1
        snapshot = updated
        persist()
    }

    /// Окончание трека. Отдельная точка входа, чтобы стрик засчитывался
    /// и за дослушанный трек, даже если старт пришёлся на прошлый день.
    func recordFinish(_ track: Track) {
        guard userID != nil else { return }

        var updated = snapshot
        let today = Self.dayKey(for: Date())
        if updated.lastListenedDay != today {
            updated.lastListenedDay = today
            updated.currentStreak = max(updated.currentStreak, 1)
            updated.longestStreak = max(updated.longestStreak, updated.currentStreak)
        }

        _ = track
        snapshot = updated
        persist()
    }

    /// Тик прослушивания. В `UserDefaults` пишем не чаще раза в 15 с:
    /// на каждый тик это лишняя запись на диск.
    func addListeningTime(_ seconds: Double) {
        guard userID != nil, seconds > 0 else { return }

        pendingSeconds += seconds

        let now = Date()
        guard now.timeIntervalSince(lastPersist) > 15 else { return }

        lastPersist = now
        snapshot.totalListeningSeconds += pendingSeconds
        pendingSeconds = 0
        persist()
    }

    // MARK: - Чтение

    var hoursPlayed: Double {
        snapshot.totalListeningSeconds / 3600
    }

    // MARK: - Хранение

    private func load(userID: Int) -> Snapshot {
        Snapshot(
            currentStreak: defaults.integer(forKey: key("streak", userID)),
            longestStreak: defaults.integer(forKey: key("longest", userID)),
            lastListenedDay: defaults.string(forKey: key("day", userID)) ?? "",
            totalListeningSeconds: defaults.double(forKey: key("seconds", userID)),
            playCountsByTrackID: Self.decodeCounts(
                defaults.data(forKey: key("plays", userID))
            )
        )
    }

    private func persist() {
        guard let userID else { return }

        let defaults = self.defaults
        let snapshot = self.snapshot
        let pending = pendingSeconds
        let streakKey = key("streak", userID)
        let longestKey = key("longest", userID)
        let dayKey = key("day", userID)
        let secondsKey = key("seconds", userID)
        let playsKey = key("plays", userID)

        persistQueue.async {
            defaults.set(snapshot.currentStreak, forKey: streakKey)
            defaults.set(snapshot.longestStreak, forKey: longestKey)
            defaults.set(snapshot.lastListenedDay, forKey: dayKey)
            defaults.set(snapshot.totalListeningSeconds + pending, forKey: secondsKey)

            if let data = try? JSONEncoder().encode(snapshot.playCountsByTrackID) {
                defaults.set(data, forKey: playsKey)
            }
        }
    }

    private func key(_ name: String, _ userID: Int) -> String {
        "listening.\(userID).\(name)"
    }

    private static func decodeCounts(_ data: Data?) -> [String: Int] {
        guard let data else { return [:] }
        return (try? JSONDecoder().decode([String: Int].self, from: data)) ?? [:]
    }

    private static func dayKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}