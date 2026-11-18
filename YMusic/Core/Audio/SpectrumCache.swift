import Foundation
import OSLog

/// Дисковый кэш спектра: `Documents/SpectrumCache/{trackID}.bin` + manifest.
///
/// Отдельный actor, а не `@MainActor`: чтение, запись и удаление файлов
/// не должны попадать на главный поток. Manifest читается один раз и
/// дальше живёт в памяти; LRU-уборка вызывается фоном после запуска
/// приложения, а не синхронно на старте.
actor SpectrumCache {
    static let shared = SpectrumCache()

    /// Сколько треков держим на диске.
    static let limit = 50

    private struct Entry: Codable {
        let frameRate: Double
        let savedAt: Date
    }

    private let logger = Logger(subsystem: "com.example.ymusic", category: "SpectrumCache")
    private var manifest: [String: Entry]?
    private var didCreateDirectory = false

    private var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpectrumCache", isDirectory: true)
    }

    private func fileURL(_ trackID: Int) -> URL {
        directory.appendingPathComponent("\(trackID).bin")
    }

    private func manifestURL() -> URL {
        directory.appendingPathComponent("manifest.json")
    }

    // MARK: - Чтение

    /// Один раз читает manifest с диска, дальше отдаёт копию из памяти.
    private func loadedManifest() -> [String: Entry] {
        if let manifest {
            return manifest
        }

        let loaded: [String: Entry]
        if let data = try? Data(contentsOf: manifestURL()) {
            loaded = (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
        } else {
            loaded = [:]
        }

        manifest = loaded
        return loaded
    }

    func load(_ trackID: Int) -> SpectrumData? {
        guard let entry = loadedManifest()["\(trackID)"] else { return nil }

        guard let data = try? Data(contentsOf: fileURL(trackID)), data.count > 16 else {
            return nil
        }

        let floats: [Float] = data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return [] }
            let count = (data.count - 16) / MemoryLayout<Float>.size
            let pointer = base.advanced(by: 16).assumingMemoryBound(to: Float.self)
            return Array(UnsafeBufferPointer(start: pointer, count: count))
        }

        guard !floats.isEmpty else { return nil }
        return SpectrumData(frameRate: entry.frameRate, frames: floats)
    }

    // MARK: - Запись

    func save(_ spectrum: SpectrumData, trackID: Int) {
        ensureDirectory()

        var data = Data()
        data.append(Data([0x53, 0x50, 0x43, 0x31])) // "SPC1"
        var bins = Int32(SpectrumData.binsCount)
        var rate = spectrum.frameRate
        withUnsafeBytes(of: &bins) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &rate) { data.append(contentsOf: $0) }
        data.append(spectrum.frames.withUnsafeBufferPointer { Data(buffer: $0) })

        do {
            try data.write(to: fileURL(trackID), options: .atomic)
        } catch {
            logger.debug("Спектр не записан: \(error.localizedDescription, privacy: .public)")
            return
        }

        var updated = loadedManifest()
        updated["\(trackID)"] = Entry(frameRate: spectrum.frameRate, savedAt: Date())
        persist(updated)
        manifest = updated

        if updated.count > Self.limit {
            prune(updated)
        }
    }

    // MARK: - Уборка

    /// Удаляет самые старые записи, если их больше лимита.
    func pruneIfNeeded() {
        let current = loadedManifest()
        guard current.count > Self.limit else { return }
        prune(current)
    }

    /// Fire-and-forget вариант для старта: ждём 5 секунд, чтобы не
    /// конкурировать с первым экраном, и только потом трогаем диск.
    func warmUp(after delay: TimeInterval = 5) async {
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        pruneIfNeeded()
    }

    private func prune(_ current: [String: Entry]) {
        var updated = current
        let overflow = updated.count - Self.limit
        guard overflow > 0 else { return }

        let oldest = updated
            .sorted { $0.value.savedAt < $1.value.savedAt }
            .prefix(overflow)

        for (key, _) in oldest {
            try? FileManager.default.removeItem(
                at: directory.appendingPathComponent("\(key).bin")
            )
            updated.removeValue(forKey: key)
        }

        persist(updated)
        manifest = updated
    }

    private func persist(_ entries: [String: Entry]) {
        ensureDirectory()
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: manifestURL(), options: .atomic)
    }

    private func ensureDirectory() {
        guard !didCreateDirectory else { return }
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        didCreateDirectory = true
    }
}