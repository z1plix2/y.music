import Accelerate
import AVFoundation
import Foundation
import OSLog

/// Спектр трека: 64 лог-полосы на кадр, кадры идут с `frameRate`.
/// Значения 0...1, хранятся построчно (кадр за кадром).
struct SpectrumData: Equatable, Sendable {
    static let binsCount = 64

    let frameRate: Double
    let frames: [Float]

    var frameCount: Int {
        frames.count / Self.binsCount
    }

    var isEmpty: Bool {
        frames.isEmpty
    }

    /// Линейная интерполяция между соседними кадрами.
    func values(at time: Double) -> [Float] {
        guard frameCount > 0 else { return [] }
        guard frameCount > 1 else {
            return Array(frames[0..<Self.binsCount])
        }

        let position = max(time * frameRate, 0)
        let index = min(Int(position), frameCount - 2)
        let fraction = Float(max(0, min(position - Double(index), 1)))

        let first = index * Self.binsCount
        let second = first + Self.binsCount
        var result = [Float](repeating: 0, count: Self.binsCount)

        for bin in 0..<Self.binsCount {
            let a = frames[first + bin]
            let b = frames[second + bin]
            result[bin] = a + (b - a) * fraction
        }
        return result
    }
}

/// Результат одного прохода по файлу: форма волны и, если нужен, спектр.
struct AudioAnalysis: Sendable {
    let waveform: [Float]
    let spectrum: SpectrumData?
}

/// Анализ трека: форма волны для скраббера и спектр для визуализатора.
///
/// Один проход `AVAudioFile` даёт оба результата: раньше каждый анализ
/// качал и декодировал файл заново. Кэш — память, `UserDefaults` (волна)
/// и `Documents/SpectrumCache` (спектр, LRU на 50 треков).
actor WaveformExtractor {
    static let shared = WaveformExtractor()

    static let binsCount = 200

    private let logger = Logger(subsystem: "com.example.ymusic", category: "Waveform")
    private var memory: [Int: [Float]] = [:]
    private var spectrumMemory: [Int: SpectrumData] = [:]
    private let defaults = UserDefaults.standard

    func waveform(for track: Track, streamURL: URL) async throws -> [Float] {
        try await analysis(for: track, streamURL: streamURL, needsSpectrum: false).waveform
    }

    func analysis(
        for track: Track,
        streamURL: URL,
        needsSpectrum: Bool
    ) async throws -> AudioAnalysis {
        let cachedWaveform = memory[track.id] ?? storedWaveform(for: track.id)

        var cachedSpectrum: SpectrumData?
        if needsSpectrum {
            if let inMemory = spectrumMemory[track.id] {
                cachedSpectrum = inMemory
            } else {
                cachedSpectrum = await SpectrumCache.shared.load(track.id)
            }
        }

        if let cachedWaveform, !needsSpectrum || cachedSpectrum != nil {
            memory[track.id] = cachedWaveform
            if let cachedSpectrum { spectrumMemory[track.id] = cachedSpectrum }
            return AudioAnalysis(waveform: cachedWaveform, spectrum: cachedSpectrum)
        }

        let localURL: URL
        do {
            localURL = try await AnalysisFileStore.shared.localFile(for: streamURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.error("Анализ: загрузка не удалась \(error.localizedDescription, privacy: .public)")
            throw error
        }

        guard !Task.isCancelled else { throw CancellationError() }

        let needsWaveform = cachedWaveform == nil
        let result = await Task.detached(priority: .utility) {
            Self.extract(
                from: localURL,
                waveformCount: Self.binsCount,
                needsWaveform: needsWaveform,
                needsSpectrum: needsSpectrum
            )
        }.value

        guard !Task.isCancelled else { throw CancellationError() }

        let waveform = cachedWaveform ?? result.waveform
        guard !waveform.isEmpty else {
            throw APIError.unavailable("Не удалось прочитать форму волны.")
        }

        memory[track.id] = waveform
        store(waveform, for: track.id)

        if let spectrum = result.spectrum {
            spectrumMemory[track.id] = spectrum
            await SpectrumCache.shared.save(spectrum, trackID: track.id)
        }

        return AudioAnalysis(
            waveform: waveform,
            spectrum: result.spectrum ?? cachedSpectrum
        )
    }

    // MARK: - Кэш формы волны

    private func storedWaveform(for trackID: Int) -> [Float]? {
        guard let stored = defaults.array(forKey: Self.cacheKey(trackID)) as? [Double],
              !stored.isEmpty
        else {
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

    private static func extract(
        from url: URL,
        waveformCount: Int,
        needsWaveform: Bool,
        needsSpectrum: Bool
    ) -> AudioAnalysis {
        guard let file = try? AVAudioFile(forReading: url) else {
            return AudioAnalysis(waveform: [], spectrum: nil)
        }

        let format = file.processingFormat
        guard format.commonFormat == .pcmFormatFloat32, format.channelCount > 0 else {
            return AudioAnalysis(waveform: [], spectrum: nil)
        }

        let sampleRate = Double(format.sampleRate)
        let totalFrames = max(file.length, 1)
        let duration = Double(totalFrames) / max(sampleRate, 1)

        let framesPerBin = max(totalFrames / Int64(max(waveformCount, 1)), 1)
        var bins = [Float](repeating: 0, count: max(waveformCount, 1))
        var globalFrame: Int64 = 0

        // Спектр: не больше 1500 кадров. Для длинных треков шаг кадров
        // растягивается, чтобы покрыть весь трек, а не первые 50 секунд.
        let frameRate = needsSpectrum
            ? min(30, 1500.0 / max(duration, 1))
            : 0
        let hop = max(Int(sampleRate / max(frameRate, 1)), 1)
        let maxSpectrumFrames = needsSpectrum
            ? min(1500, Int(duration * frameRate))
            : 0

        var spectrumFrames: [Float] = []
        if needsSpectrum, maxSpectrumFrames > 0 {
            spectrumFrames.reserveCapacity(maxSpectrumFrames * SpectrumData.binsCount)
        }

        var fftSetup: FFTSetup?
        var window = [Float](repeating: 0, count: 1024)
        var bandRanges: [(lower: Int, upper: Int)] = []
        let halfSize = 512

        if needsSpectrum, maxSpectrumFrames > 0 {
            vDSP_hann_window(&window, vDSP_Length(1024), Int32(vDSP_HANN_NORM))

            if let setup = vDSP_create_fftsetup(9, FFTRadix(kFFTRadix2)) {
                fftSetup = setup
                bandRanges = Self.bandRanges(
                    sampleRate: sampleRate,
                    binCount: SpectrumData.binsCount,
                    halfSize: halfSize
                )
            }
        }

        defer {
            if let fftSetup {
                vDSP_destroy_fftsetup(fftSetup)
            }
        }

        let chunkFrames: AVAudioFrameCount = 8192
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            return AudioAnalysis(waveform: [], spectrum: nil)
        }

        var pending: [Float] = []
        pending.reserveCapacity(Int(chunkFrames) + 2048)
        var pendingBase = 0
        var nextSpectrumFrame = 0

        var real = [Float](repeating: 0, count: halfSize)
        var imag = [Float](repeating: 0, count: halfSize)
        var magnitudes = [Float](repeating: 0, count: halfSize)
        var windowed = [Float](repeating: 0, count: 1024)

        while true {
            if Task.isCancelled {
                return AudioAnalysis(waveform: [], spectrum: nil)
            }

            do {
                try file.read(into: buffer, frameCount: chunkFrames)
            } catch {
                break
            }

            let frames = Int(buffer.frameLength)
            guard frames > 0, let channels = buffer.floatChannelData else { break }
            let channel = channels[0]

            if needsWaveform {
                for index in 0..<frames {
                    let bin = Int(globalFrame / framesPerBin)
                    if bin < waveformCount {
                        bins[bin] = max(bins[bin], abs(channel[index]))
                    }
                    globalFrame += 1
                }
            } else {
                globalFrame += Int64(frames)
            }

            guard
                needsSpectrum,
                let fftSetup,
                nextSpectrumFrame < maxSpectrumFrames
            else { continue }

            pending.append(contentsOf: UnsafeBufferPointer(start: channel, count: frames))

            while nextSpectrumFrame < maxSpectrumFrames {
                let start = nextSpectrumFrame * hop
                let offset = start - pendingBase

                guard offset >= 0, offset + 1024 <= pending.count else { break }

                for index in 0..<1024 {
                    windowed[index] = pending[offset + index]
                }

                vDSP_vmul(windowed, 1, window, 1, &windowed, 1, 1024)

                real.withUnsafeMutableBufferPointer { realPtr in
                    imag.withUnsafeMutableBufferPointer { imagPtr in
                        guard
                            let realBase = realPtr.baseAddress,
                            let imagBase = imagPtr.baseAddress
                        else {
                            return
                        }

                        var split = DSPSplitComplex(realp: realBase, imagp: imagBase)
                        windowed.withUnsafeBufferPointer { windowPtr in
                            guard let base = windowPtr.baseAddress else { return }
                            base.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) { complex in
                                vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(halfSize))
                            }
                        }

                        vDSP_fft_zrip(
                            fftSetup,
                            &split,
                            1,
                            vDSP_Length(9),
                            FFTDirection(FFT_FORWARD)
                        )
                        vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(halfSize))
                    }
                }

                for range in bandRanges {
                    var sum: Float = 0
                    for bin in range.lower...range.upper {
                        sum += magnitudes[bin]
                    }
                    let count = Float(max(range.upper - range.lower + 1, 1))
                    spectrumFrames.append(sum / count)
                }

                nextSpectrumFrame += 1
            }

            let consumed = nextSpectrumFrame * hop - pendingBase
            if consumed > 0 {
                let drop = min(consumed, pending.count)
                pending.removeFirst(drop)
                pendingBase += drop
            }

            if nextSpectrumFrame >= maxSpectrumFrames {
                pending.removeAll(keepingCapacity: false)
            }
        }

        let peak = bins.max() ?? 0
        let waveform = peak > 0
            ? bins.map { min(max($0 / peak, 0), 1) }
            : []

        var spectrum: SpectrumData?
        if needsSpectrum, !spectrumFrames.isEmpty {
            let maxValue = spectrumFrames.max() ?? 0
            if maxValue > 0 {
                let normalized = spectrumFrames.map { value in
                    min(max(sqrt(value) / sqrt(maxValue), 0), 1)
                }
                spectrum = SpectrumData(frameRate: frameRate, frames: normalized)
            }
        }

        return AudioAnalysis(waveform: waveform, spectrum: spectrum)
    }

    /// Логарифмическая сетка 20 Гц ... 20 кГц (или Найквист).
    private static func bandRanges(
        sampleRate: Double,
        binCount: Int,
        halfSize: Int
    ) -> [(lower: Int, upper: Int)] {
        let nyquist = sampleRate / 2
        let minFrequency = 20.0
        let maxFrequency = min(20000.0, nyquist * 0.95)
        let binWidth = nyquist / Double(halfSize)

        var ranges: [(lower: Int, upper: Int)] = []
        ranges.reserveCapacity(binCount)

        for index in 0..<binCount {
            let lowFrequency = minFrequency
                * pow(maxFrequency / minFrequency, Double(index) / Double(binCount))
            let highFrequency = minFrequency
                * pow(maxFrequency / minFrequency, Double(index + 1) / Double(binCount))

            let lower = max(1, min(Int(lowFrequency / binWidth), halfSize - 1))
            let upper = max(lower, min(Int(highFrequency / binWidth), halfSize - 1))
            ranges.append((lower, upper))
        }

        return ranges
    }
}