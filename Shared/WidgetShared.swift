import Foundation

/// Снимок текущего трека для виджета. Отдельный тип, потому что виджет
/// не может читать `@MainActor`-объекты приложения: обмен идёт через
/// `UserDefaults` общего App Group.
struct WidgetTrackSnapshot: Codable, Equatable, Sendable {
    let id: Int
    let title: String
    let artist: String
    let artworkURLString: String?
    let isPlaying: Bool
    let currentTime: Double
    let duration: Double
    let updatedAt: Date

    /// Позиция на момент `date`: пока играет, прогресс идёт сам,
    /// потому что виджет обновляется редко.
    func position(at date: Date) -> Double {
        guard duration > 0 else { return 0 }
        let base = isPlaying
            ? currentTime + max(0, date.timeIntervalSince(updatedAt))
            : currentTime
        return min(max(base, 0), duration) / duration
    }
}

/// Единая точка доступа к общей папке для приложения и виджета.
///
/// Если App Group недоступна (например, сборка без подписи), запись просто
/// не происходит — приложение продолжает работать, а виджет показывает
/// заглушку. Это лучше, чем падать на отсутствии контейнера.
enum WidgetSharedStore {
    static let appGroupID = "group.com.example.ymusic"
    static let snapshotKey = "widget.trackSnapshot"

    static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    static var containerURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        )
    }

    static func save(_ snapshot: WidgetTrackSnapshot) {
        guard
            let defaults,
            let data = try? JSONEncoder().encode(snapshot)
        else { return }

        defaults.set(data, forKey: snapshotKey)
    }

    static func load() -> WidgetTrackSnapshot? {
        guard
            let data = defaults?.data(forKey: snapshotKey),
            let snapshot = try? JSONDecoder().decode(WidgetTrackSnapshot.self, from: data)
        else {
            return nil
        }
        return snapshot
    }

    static func clear() {
        defaults?.removeObject(forKey: snapshotKey)
    }
}