import Foundation

/// Очередь воспроизведения без побочных эффектов: чистая структура,
/// чтобы её можно было проверить без плеера и сети.
struct PlaybackQueue: Equatable, Sendable {
    enum RepeatMode: String, CaseIterable, Sendable {
        case off
        case all
        case one
    }

    private(set) var tracks: [Track]
    /// Порядок воспроизведения: индексы в `tracks`. При выключенном shuffle
    /// совпадает с `tracks.indices`.
    private var order: [Int]
    private(set) var position: Int

    private(set) var isShuffled: Bool
    private(set) var repeatMode: RepeatMode

    init(
        tracks: [Track] = [],
        startAt index: Int = 0,
        isShuffled: Bool = false,
        repeatMode: RepeatMode = .off
    ) {
        self.tracks = tracks
        self.isShuffled = isShuffled
        self.repeatMode = repeatMode

        guard !tracks.isEmpty else {
            self.order = []
            self.position = 0
            return
        }

        let clamped = min(max(index, 0), tracks.count - 1)
        if isShuffled {
            self.order = [clamped] + tracks.indices.filter { $0 != clamped }.shuffled()
        } else {
            self.order = Array(tracks.indices)
        }
        self.position = 0
    }

    var isEmpty: Bool { tracks.isEmpty }

    var currentTrack: Track? {
        guard order.indices.contains(position) else { return nil }
        let index = order[position]
        guard tracks.indices.contains(index) else { return nil }
        return tracks[index]
    }

    var upNextCount: Int {
        guard repeatMode == .all else { return max(0, order.count - position - 1) }
        return max(0, order.count - 1)
    }

    // MARK: - Управление

    /// `offset = 1` — следующий, `-1` — предыдущий. `nil` означает,
    /// что очередь закончилась (repeat выключен) и играть больше нечего.
    mutating func advance(by offset: Int) -> Track? {
        guard !order.isEmpty else { return nil }

        let candidate = position + offset
        if order.indices.contains(candidate) {
            position = candidate
        } else if repeatMode == .all, offset > 0 {
            position = 0
        } else if repeatMode == .all, offset < 0 {
            position = order.count - 1
        } else {
            return nil
        }

        return currentTrack
    }

    mutating func toggleShuffle() {
        isShuffled.toggle()
        guard !order.isEmpty, order.indices.contains(position) else { return }

        let currentIndex = order[position]
        if isShuffled {
            order = [currentIndex] + order.filter { $0 != currentIndex }.shuffled()
            position = 0
        } else {
            order = Array(tracks.indices)
            position = currentIndex
        }
    }

    mutating func cycleRepeat() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    /// Дописывает треки в конец очереди: «Моя волна» приносит партии,
    /// пока играет предыдущая. Порядок при shuffle не пересобирается —
    /// новые треки просто встают в конец уже перемешанной очереди.
    mutating func append(contentsOf newTracks: [Track]) {
        guard !newTracks.isEmpty else { return }
        let start = tracks.count
        tracks.append(contentsOf: newTracks)
        order.append(contentsOf: start..<(start + newTracks.count))
    }
}
