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
            self.position = 0
        } else {
            self.order = Array(tracks.indices)
            // Без shuffle стартовый индекс — это позиция в обычном порядке.
            // Раньше здесь всегда был 0, и `play(tracks:startAt:)` запускал
            // первый трек независимо от того, какой выбрал пользователь.
            self.position = clamped
        }
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

    // MARK: - Очередь из экрана «Дальше»

    /// Треки после текущего в реальном порядке воспроизведения. Индекс —
    /// позиция в `tracks`, чтобы по нему можно было удалять.
    var upNext: [(index: Int, track: Track)] {
        guard order.indices.contains(position) else { return [] }
        return order.dropFirst(position + 1).compactMap { index in
            guard tracks.indices.contains(index) else { return nil }
            return (index, tracks[index])
        }
    }

    /// Вставляет трек сразу после текущего. На пустой очереди становится
    /// первым, но воспроизведение не запускает — это решает вызывающий.
    mutating func insertNext(_ track: Track) {
        tracks.append(track)
        let newIndex = tracks.count - 1

        guard !order.isEmpty, order.indices.contains(position) else {
            order = [newIndex]
            position = 0
            return
        }

        order.insert(newIndex, at: min(position + 1, order.count))
    }

    /// Добавляет трек в конец очереди.
    mutating func append(_ track: Track) {
        tracks.append(track)
        order.append(tracks.count - 1)

        if order.count == 1 {
            position = 0
        }
    }

    /// Удаляет трек по индексу в `tracks`. Если удалён текущий, `position`
    /// указывает на следующий; на последнем — на предыдущий.
    mutating func remove(at index: Int) {
        guard tracks.indices.contains(index) else { return }

        let removedOrderPosition = order.firstIndex(of: index)

        tracks.remove(at: index)
        order = order.compactMap { value in
            if value == index { return nil }
            return value > index ? value - 1 : value
        }

        guard !order.isEmpty else {
            position = 0
            return
        }

        if let removedOrderPosition {
            if removedOrderPosition < position {
                position -= 1
            }
        }

        position = min(max(position, 0), order.count - 1)
    }

    /// Перестановка в секции «Дальше». Индексы — относительные, как их
    /// отдаёт `ForEach.onMove` SwiftUI.
    mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let start = position + 1
        guard start < order.count else { return }

        var slice = Array(order[start...])
        slice.move(fromOffsets: source, toOffset: destination)
        order.replaceSubrange(start..., with: slice)
    }

    /// Очистка очереди. С `keepingCurrent` остаётся только играющий трек.
    mutating func clear(keepingCurrent: Bool) {
        if keepingCurrent, let current = currentTrack {
            tracks = [current]
            order = [0]
            position = 0
        } else {
            tracks = []
            order = []
            position = 0
        }
    }
}
