import Foundation
import OSLog

/// Трек в том виде, в котором он лежит в `UserDefaults`:
/// минимум полей для восстановления очереди и «Недавнего».
struct StoredTrack: Codable, Equatable, Sendable {
    let id: Int
    let title: String
    let artist: String
    let artwork: String?
    let duration: Double

    init(track: Track) {
        id = track.id
        title = track.title
        artist = track.artistLine
        artwork = track.artworkURL?.absoluteString
        duration = track.duration
    }

    var track: Track {
        Track(
            id: id,
            title: title,
            artistName: artist,
            durationSeconds: duration,
            artworkURLString: artwork
        )
    }
}

struct StoredPlayback: Codable, Equatable, Sendable {
    let tracks: [StoredTrack]
    let index: Int
    let position: Double
    let shuffle: Bool
    let repeatMode: String
    let volume: Float
}

/// Состояние воспроизведения в `UserDefaults` — не секреты, Keychain не нужен.
/// Ключи разделены по `userID`: смена аккаунта не тянет чужую очередь.
@MainActor
final class PlaybackStateStore {
    static let shared = PlaybackStateStore()

    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.example.ymusic", category: "PlaybackState")
    /// Кодирование очереди до 200 треков — не работа для главного потока.
    /// Серийная очередь сохраняет порядок записей.
    private let persistQueue = DispatchQueue(
        label: "com.example.ymusic.playback-state",
        qos: .utility
    )

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Очередь

    func save(_ snapshot: StoredPlayback, userID: Int) {
        let defaults = self.defaults
        persistQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            defaults.set(data, forKey: Self.queueKey(userID))
        }
    }

    func load(userID: Int) -> StoredPlayback? {
        guard let data = defaults.data(forKey: Self.queueKey(userID)) else { return nil }
        return try? JSONDecoder().decode(StoredPlayback.self, from: data)
    }

    // MARK: - Недавние

    func saveRecents(_ tracks: [StoredTrack], userID: Int) {
        let defaults = self.defaults
        let slice = Array(tracks.prefix(20))
        persistQueue.async {
            guard let data = try? JSONEncoder().encode(slice) else { return }
            defaults.set(data, forKey: Self.recentsKey(userID))
        }
    }

    func loadRecents(userID: Int) -> [StoredTrack] {
        guard let data = defaults.data(forKey: Self.recentsKey(userID)) else { return [] }
        return (try? JSONDecoder().decode([StoredTrack].self, from: data)) ?? []
    }

    func clear(userID: Int) {
        defaults.removeObject(forKey: Self.queueKey(userID))
    }

    // MARK: - Ключи

    private static func queueKey(_ userID: Int) -> String {
        "ymusic.playback.queue.\(userID)"
    }

    private static func recentsKey(_ userID: Int) -> String {
        "ymusic.playback.recents.\(userID)"
    }
}
