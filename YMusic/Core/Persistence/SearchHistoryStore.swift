import Foundation

/// История поиска в `UserDefaults` — не секреты, Keychain не нужен.
/// Ключ разделён по `userID`: чужой запрос из другой учётки не покажется.
@MainActor
final class SearchHistoryStore {
    static let shared = SearchHistoryStore()

    /// Последние запросы; старые вытесняются.
    private let limit = 10

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(userID: Int) -> [String] {
        defaults.stringArray(forKey: Self.key(userID)) ?? []
    }

    /// Возвращает обновлённый список: запрос переезжает на первое место,
    /// дубликаты (без учёта регистра) не накапливаются.
    @discardableResult
    func record(_ query: String, userID: Int) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return load(userID: userID) }

        var items = load(userID: userID)
        items.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        items.insert(trimmed, at: 0)
        items = Array(items.prefix(limit))

        defaults.set(items, forKey: Self.key(userID))
        return items
    }

    func clear(userID: Int) {
        defaults.removeObject(forKey: Self.key(userID))
    }

    private static func key(_ userID: Int) -> String {
        "ymusic.search.history.\(userID)"
    }
}
