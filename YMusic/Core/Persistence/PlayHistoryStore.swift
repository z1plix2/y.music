import Combine
import Foundation

/// Одна запись истории: трек и момент, когда его включили.
struct HistoryEntry: Codable, Identifiable, Equatable, Sendable {
    let track: StoredTrack
    let lastPlayedAt: Date

    var id: Int { track.id }
}

/// История прослушиваний на 200 треков.
///
/// Отдельно от `PlaybackStateStore.recents`: там только 20 позиций для
/// главной, без дат. Здесь дата нужна для группировки «Сегодня / Вчера»
/// и для «Забытого» (не играло больше 30 дней).
@MainActor
final class PlayHistoryStore: ObservableObject {
    static let shared = PlayHistoryStore()

    /// Больше не храним: 200 записей хватает на несколько недель.
    static let limit = 200

    @Published private(set) var entries: [HistoryEntry] = []

    private let defaults: UserDefaults
    /// JSON на 200 записей — не работа для главного потока.
    private let persistQueue = DispatchQueue(
        label: "com.example.ymusic.play-history",
        qos: .utility
    )
    private var userID: Int?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Профиль

    func configure(userID: Int) {
        guard self.userID != userID else { return }
        self.userID = userID
        entries = load(userID: userID)
    }

    func detach() {
        userID = nil
        entries = []
    }

    // MARK: - Запись

    /// Трек поднялся наверх истории. Один трек — одна запись: дата
    /// обновляется, дубликаты не копятся.
    func record(_ track: Track, userID: Int) {
        if self.userID != userID {
            configure(userID: userID)
        }

        var updated = entries
        updated.removeAll { $0.id == track.id }
        updated.insert(
            HistoryEntry(track: StoredTrack(track: track), lastPlayedAt: Date()),
            at: 0
        )
        entries = Array(updated.prefix(Self.limit))
        persist()
    }

    // MARK: - Чтение

    func lastPlayedAt(for trackID: Int) -> Date? {
        entries.first { $0.id == trackID }?.lastPlayedAt
    }

    /// Сколько дней прошло с последнего прослушивания (nil — не играл).
    func daysSincePlayed(_ trackID: Int) -> Int? {
        guard let date = lastPlayedAt(for: trackID) else { return nil }
        let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day
        return days.map { max(0, $0) }
    }

    // MARK: - Хранение

    private func load(userID: Int) -> [HistoryEntry] {
        guard let data = defaults.data(forKey: Self.key(userID)) else { return [] }
        return (try? JSONDecoder().decode([HistoryEntry].self, from: data)) ?? []
    }

    private func persist() {
        guard let userID else { return }

        let defaults = self.defaults
        let entries = self.entries
        let key = Self.key(userID)

        persistQueue.async {
            guard let data = try? JSONEncoder().encode(entries) else { return }
            defaults.set(data, forKey: key)
        }
    }

    private static func key(_ userID: Int) -> String {
        "ymusic.playback.history.\(userID)"
    }
}