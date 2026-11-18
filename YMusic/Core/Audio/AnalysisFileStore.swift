import Foundation
import OSLog

/// Один временный файл трека на все фоновые анализы.
///
/// Раньше вибро и форма волны качали один и тот же трек каждый сам:
/// до трёх загрузок на трек (AVPlayer + два анализа). Теперь оба идут
/// через этот актор: первый качает, второй ждёт тот же `Task` и получает
/// готовый URL. Файл живёт до смены трека (`clear()` из `AudioPlayer`).
actor AnalysisFileStore {
    static let shared = AnalysisFileStore()

    private let logger = Logger(subsystem: "com.example.ymusic", category: "AnalysisFiles")
    private var files: [String: URL] = [:]
    private var inFlight: [String: Task<URL, Error>] = [:]

    func localFile(for remote: URL) async throws -> URL {
        let key = remote.absoluteString

        if let existing = files[key], FileManager.default.fileExists(atPath: existing.path) {
            return existing
        }

        if let running = inFlight[key] {
            return try await running.value
        }

        let task = Task<URL, Error> { [weak self] in
            let local = try await Self.download(remote)
            await self?.store(local, for: key)
            return local
        }
        inFlight[key] = task

        defer { inFlight[key] = nil }

        do {
            return try await task.value
        } catch {
            logger.debug("Анализ: загрузка не удалась \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Смена трека или `teardown`: все временные файлы больше не нужны.
    func clear() {
        for task in inFlight.values {
            task.cancel()
        }
        inFlight.removeAll()

        for url in files.values {
            try? FileManager.default.removeItem(at: url)
        }
        files.removeAll()
    }

    private func store(_ url: URL, for key: String) {
        files[key] = url
    }

    private static func download(_ remote: URL) async throws -> URL {
        var request = URLRequest(url: remote)
        request.timeoutInterval = 30

        let (temporary, response) = try await URLSession.shared.download(for: request)

        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            throw APIError.http(status: http.statusCode, payload: nil)
        }

        let ext = remote.pathExtension.isEmpty ? "mp3" : remote.pathExtension
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("analysis-\(UUID().uuidString).\(ext)")

        try FileManager.default.moveItem(at: temporary, to: target)
        return target
    }
}