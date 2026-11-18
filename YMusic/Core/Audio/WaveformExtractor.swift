import AVFoundation
import Foundation
import OSLog

/// Форма волны для скраббера: 200 столбиков 0…1.
///
/// Источник — тот же файл, что играет AVPlayer. Скачиваем во временный файл
/// (иначе `AVAudioFile` не открыть), читаем PCM и берём максимум модуля
/// амплитуды на каждый бин. Кэш — память + `UserDefaults`, чтобы повторное
/// открытие трека не ходило в сеть.
actor WaveformExtractor {
    static let shared = WaveformExtractor()

    static let binsCount = 200

    private let logger = Logger(subsystem: "com.example.ymusic", category: "Waveform")
    private var memory: [Int: [Float]] = [:]
    private let defaults = UserDefaults.standard

    func waveform(for track: Track, streamURL: URL) async throws -> [Float] {
        if let cached = memory[track.id] {
            return cached
        }

        if let stored = storedWaveform(for: track.id) {
            memory[track.id] = stored
            return stored
        }

        let localURL: URL
        do {
            localURL = try await AnalysisFileStore.shared.localFile(for: streamURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.error("Форма волны: загрузка не удалась \(error.localizedDescription, privacy: .public)")
            throw error
        }

        guard !Task.isCancelled else { throw CancellationError() }

        let bins = Self.extract(from: localURL, count: Self.binsCount)
        guard !bins.isEmpty else {
            throw APIError.unavailable("Не удалось прочитать форму волны.")
        }

        memory[track.id] = bins
        store(bins, for: track.id)
        return bins
    }

    // MARK: - Кэш

    private func storedWaveform(for trackID: Int) -> [Float]? {
        let key = Self.cacheKey(trackID)
        guard let stored = defaults.array(forKey: key) as? [Double], !stored.isEmpty else {
            return nil
        }
        return stored.map(Float.init)
    }

    private func store(_ bins: [Float], for trackID: Int) {
        defaults.set(bins.map(Double.init), forKey: Self.cacheKey(trackID))
    }

    private static func cacheKey(_ trackID: Int) -> String {
        "waveform.\(trackID)"
    }

    // MARK: - Разбор

    private static func extract(from url: URL, count: Int) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url) else { return [] }
        let format = file.processingFormat
        guard format.commonFormat == .pcmFormatFloat32, format.channelCount > 0 else {
            return []
        }

        let totalFrames = max(file.length, 1)
        let framesPerBin = max(totalFrames / Int64(count), 1)

        var bins = [Float](repeating: 0, count: count)
        var globalFrame: Int64 = 0

        let chunkFrames: AVAudioFrameCount = 8192
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            return []
        }

        while true {
            if Task.isCancelled { return [] }

            do {
                try file.read(into: buffer, frameCount: chunkFrames)
            } catch {
                break
            }

            let frames = Int(buffer.frameLength)
            guard frames > 0, let channels = buffer.floatChannelData else { break }

            let channel = channels[0]
            for index in 0..<frames {
                let bin = Int(globalFrame / framesPerBin)
                if bin < count {
                    bins[bin] = max(bins[bin], abs(channel[index]))
                }
                globalFrame += 1
            }
        }

        let peak = bins.max() ?? 0
        guard peak > 0 else { return [] }

        return bins.map { min(max($0 / peak, 0), 1) }
    }
}