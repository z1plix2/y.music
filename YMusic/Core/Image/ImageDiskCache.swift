import CryptoKit
import Foundation
import OSLog

/// Дисковый кэш обложек: переживает перезапуск и работает без сети.
///
/// Память (`NSCache` в `ImageLoader`) и диск решают разные задачи: память
/// быстрая, но живёт до выгрузки, диск медленнее, но обложки не перекачиваются
/// каждый холодный старт. Хранится исходный ответ — декодирование всё равно
/// идёт через даунсемплинг `ImageLoader`.
actor ImageDiskCache {
    static let shared = ImageDiskCache()

    private let logger = Logger(subsystem: "com.example.ymusic", category: "ImageDiskCache")
    private let directory: URL
    private let fileLimit = 600
    private let byteLimit = 120 * 1024 * 1024
    private var didTrim = false

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        directory = caches.appendingPathComponent("covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func data(for key: String) -> Data? {
        let file = fileURL(for: key)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }

        do {
            let data = try Data(contentsOf: file)
            // Обновляем mtime: это метка «недавно нужна» для LRU-уборки.
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()],
                ofItemAtPath: file.path
            )
            return data
        } catch {
            logger.debug("Кэш обложек: чтение не удалось \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func store(_ data: Data, key: String) {
        do {
            try data.write(to: fileURL(for: key), options: .atomic)
        } catch {
            logger.debug("Кэш обложек: запись не удалась \(error.localizedDescription, privacy: .public)")
        }

        if !didTrim {
            didTrim = true
            trimIfNeeded()
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Внутреннее

    private func fileURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name).appendingPathExtension("img")
    }

    /// Уборка по количеству и объёму: старые по дате модификации уходят первыми.
    private func trimIfNeeded() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        var entries: [(url: URL, date: Date, size: Int)] = []
        var totalBytes = 0

        for file in files {
            let values = try? file.resourceValues(forKeys: Set(keys))
            let size = values?.fileSize ?? 0
            totalBytes += size
            entries.append((file, values?.contentModificationDate ?? .distantPast, size))
        }

        entries.sort { $0.date < $1.date }

        var remaining = totalBytes
        var index = 0
        while index < entries.count,
              (entries.count - index > fileLimit || remaining > byteLimit) {
            try? FileManager.default.removeItem(at: entries[index].url)
            remaining -= entries[index].size
            index += 1
        }
    }
}
