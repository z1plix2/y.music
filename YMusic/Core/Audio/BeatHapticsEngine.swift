import Accelerate
import AVFoundation
import CoreHaptics
import Foundation
import OSLog

/// Событие в музыке, под которое бьёт вибро. Таймкод — секунды от начала.
struct BeatEvent: Sendable {
    enum Kind: Sendable {
        case kick
        case snare
        case hat
    }

    let time: Double
    let kind: Kind
}

/// Аппаратная поддержка вибро. Отдельный nonisolated-тип, чтобы значение
/// можно было читать из `View` без изоляции на MainActor.
enum BeatHapticsSupport {
    static let isSupported = CHHapticEngine.capabilitiesForHardware().supportsHaptics
}

/// Вибро в такт музыке.
///
/// Почему не tap с `AVPlayer`: он не отдаёт буферы. Поэтому трек скачивается
/// во временный файл, `AVAudioFile` читает PCM, `vDSP` считает FFT по кадрам
/// 1024/512, а готовые таймкоды событий проигрываются по `player.currentTime`.
/// Отдельный аудиовыход не нужен: анализ идёт заранее, в фоне, одним проходом.
///
/// `CoreHaptics` на симуляторе не поддерживается — `isSupported` вернёт false,
/// и весь движок тихо выключается.
@MainActor
final class BeatHapticsEngine {
    /// Тик опроса позиции плеера: 50 мс. Для попадания в бит хватает,
    /// а CPU-пробуждений в 2.5 раза меньше, чем на 20 мс.
    private static let tickSeconds: UInt64 = 50_000_000

    private let logger = Logger(subsystem: "com.example.ymusic", category: "BeatHaptics")

    /// Позиция воспроизведения. Задаёт `AudioPlayer`; слабая ссылка внутри
    /// замыкания не даёт циклу «плеер → движок → плеер».
    var timeProvider: (() -> Double)?

    private var hapticEngine: CHHapticEngine?
    private var fileURL: URL?
    private var events: [BeatEvent] = []
    private var cursor = 0
    private var lastTickTime = 0.0
    private var isPaused = true
    private var isStopping = false
    private var generation = 0
    private var ticker: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?

    // MARK: - Управление

    func start(streamURL: URL) {
        stop()

        generation += 1
        let generation = generation
        isPaused = false

        hapticEngine = makeEngine()

        analysisTask = Task { [weak self] in
            guard let self else { return }
            await self.prepare(url: streamURL, generation: generation)
        }
    }

    /// Пауза: гасим и тик, и сам haptic-движок. Держать CHHapticEngine
    /// активным на паузе незачем — это лишние пробуждения и нагрев.
    func pause() {
        isPaused = true
        ticker?.cancel()
        ticker = nil
        hapticEngine?.stop(completionHandler: nil)
        hapticEngine = nil
    }

    /// Уход в фон: трек может играть дальше, но вибро в кармане не нужно.
    /// События и временный файл остаются, чтобы возврат был мгновенным.
    func suspend() {
        pause()
    }

    func resume() {
        guard !events.isEmpty, BeatHapticsSupport.isSupported else { return }
        isPaused = false

        let time = timeProvider?() ?? 0
        lastTickTime = time
        cursor = firstEventIndex(at: time)

        if hapticEngine == nil {
            hapticEngine = makeEngine()
        }
        startTicker()
    }

    func stop() {
        generation += 1
        isStopping = true
        ticker?.cancel()
        ticker = nil
        analysisTask?.cancel()
        analysisTask = nil
        events = []
        cursor = 0
        isPaused = true

        hapticEngine?.stop(completionHandler: nil)
        hapticEngine = nil
        fileURL = nil

        isStopping = false
    }

    deinit {
        generation += 1
        ticker?.cancel()
        analysisTask?.cancel()
        hapticEngine?.stop(completionHandler: nil)
    }

    // MARK: - Подготовка

    private func prepare(url: URL, generation: Int) async {
        let localURL: URL
        do {
            localURL = try await AnalysisFileStore.shared.localFile(for: url)
        } catch is CancellationError {
            return
        } catch {
            logger.error("Не удалось скачать трек для вибро: \(error.localizedDescription, privacy: .public)")
            return
        }

        guard generation == self.generation, !Task.isCancelled else { return }
        fileURL = localURL

        let analysis = Task.detached(priority: .utility) {
            BeatAnalyzer.events(from: localURL)
        }
        let detected = await analysis.value

        guard generation == self.generation, !Task.isCancelled else { return }

        events = detected
        logger.info("Вибро: размечено \(detected.count, privacy: .public) событий")

        guard BeatHapticsSupport.isSupported, !isPaused else { return }
        startTicker()
    }

    // MARK: - Пульс

    private func startTicker() {
        ticker?.cancel()
        lastTickTime = timeProvider?() ?? 0
        cursor = firstEventIndex(at: lastTickTime)

        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.tick()
                do {
                    try await Task.sleep(nanoseconds: BeatHapticsEngine.tickSeconds)
                } catch {
                    return
                }
            }
        }
    }

    private func tick() {
        guard !isPaused, !events.isEmpty else { return }

        let now = timeProvider?() ?? 0

        // Seek назад, повтор трека или смена трека: переставляем курсор,
        // иначе события «в прошлом» выстрелят пачкой. Большой прыжок вперёд
        // (перемотка, буферизация) тоже пропускаем, а не догоняем пачкой.
        if now + 0.4 < lastTickTime || now - lastTickTime > 1.0 {
            cursor = firstEventIndex(at: now)
        }

        while cursor < events.count, events[cursor].time <= now + 0.02 {
            fire(events[cursor].kind)
            cursor += 1
        }

        lastTickTime = now
    }

    private func firstEventIndex(at time: Double) -> Int {
        events.firstIndex { $0.time >= time } ?? events.count
    }

    // MARK: - Haptics

    private func makeEngine() -> CHHapticEngine? {
        guard BeatHapticsSupport.isSupported else { return nil }

        do {
            let engine = try CHHapticEngine()
            engine.playsHapticsOnly = true
            // Движок сам уснёт после простоя; пауза и фон его и так гасят.
            engine.isAutoShutdownEnabled = true

            engine.stoppedHandler = { [weak self] reason in
                Task { @MainActor in
                    self?.handleStopped(reason)
                }
            }
            engine.resetHandler = { [weak self] in
                Task { @MainActor in
                    self?.handleReset()
                }
            }

            try engine.start()
            return engine
        } catch {
            logger.error("CHHapticEngine не запустился: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func handleStopped(_ reason: CHHapticEngine.StoppedReason) {
        guard !isStopping else { return }
        logger.debug("CHHapticEngine остановился: \(reason.rawValue, privacy: .public)")
        restartEngine()
    }

    private func handleReset() {
        guard !isStopping else { return }
        restartEngine()
    }

    private func restartEngine() {
        guard !isStopping, BeatHapticsSupport.isSupported else { return }

        if hapticEngine == nil {
            hapticEngine = makeEngine()
            return
        }

        do {
            try hapticEngine?.start()
        } catch {
            logger.error("CHHapticEngine не перезапустился: \(error.localizedDescription, privacy: .public)")
            hapticEngine = nil
        }
    }

    private func fire(_ kind: BeatEvent.Kind) {
        guard let hapticEngine else { return }

        let intensity: Float
        let sharpness: Float

        switch kind {
        case .kick:
            intensity = 0.9
            sharpness = 0.3
        case .snare:
            intensity = 0.6
            sharpness = 0.6
        case .hat:
            intensity = 0.3
            sharpness = 0.9
        }

        let event = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
            ],
            relativeTime: 0
        )

        do {
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try hapticEngine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            logger.debug("Паттерн вибро: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Анализ

/// Один проход по PCM: FFT 1024, hop 512, три полосы, авто-порог по первым
/// двум секундам. Возвращает отсортированные по времени события.
enum BeatAnalyzer {
    private static let fftSize = 1024
    private static let hop = 512

    static func events(from url: URL) -> [BeatEvent] {
        guard let file = try? AVAudioFile(forReading: url) else { return [] }
        let format = file.processingFormat
        guard format.commonFormat == .pcmFormatFloat32, format.channelCount > 0 else {
            return []
        }

        let sampleRate = Float(format.sampleRate)
        guard sampleRate > 0 else { return [] }

        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        let log2n = vDSP_Length(log2(Float(fftSize)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return []
        }
        defer { vDSP_destroy_fftsetup(setup) }

        let binWidth = sampleRate / Float(fftSize)
        let bassRange = 1...max(1, Int(150 / binWidth))
        let midRange = (bassRange.upperBound + 1)...max(bassRange.upperBound + 1, Int(2000 / binWidth))
        guard midRange.upperBound + 1 < fftSize / 2 else { return [] }
        let highRange = (midRange.upperBound + 1)...(fftSize / 2 - 1)

        let chunkFrames: AVAudioFrameCount = 4096
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            return []
        }

        var pending: [Float] = []
        pending.reserveCapacity(fftSize * 2)
        var globalSample = 0
        var frames: [(time: Double, bass: Float, mid: Float, high: Float)] = []

        while true {
            if Task.isCancelled {
                return []
            }

            do {
                try file.read(into: buffer, frameCount: chunkFrames)
            } catch {
                break
            }

            let count = Int(buffer.frameLength)
            guard count > 0, let channels = buffer.floatChannelData else { break }

            let channel = channels[0]
            for index in 0..<count {
                pending.append(channel[index])
            }

            while pending.count >= fftSize {
                let slice = Array(pending[0..<fftSize])
                let time = Double(globalSample) / Double(sampleRate)

                if let energy = analyse(
                    slice,
                    window: window,
                    setup: setup,
                    log2n: log2n,
                    bassRange: bassRange,
                    midRange: midRange,
                    highRange: highRange
                ) {
                    frames.append((time, energy.0, energy.1, energy.2))
                }

                pending.removeFirst(hop)
                globalSample += hop
            }
        }

        guard frames.count > 4 else { return [] }

        let bassThreshold = threshold(frames.map { $0.bass }, times: frames.map { $0.time })
        let midThreshold = threshold(frames.map { $0.mid }, times: frames.map { $0.time })
        let highThreshold = threshold(frames.map { $0.high }, times: frames.map { $0.time })

        var result: [BeatEvent] = []
        var lastBass = -1.0
        var lastMid = -1.0
        var lastHigh = -1.0
        var lastAny = -1.0

        for index in 1..<frames.count {
            let frame = frames[index]
            let previous = frames[index - 1]

            var candidate: BeatEvent.Kind?

            if frame.bass > bassThreshold,
               frame.bass > previous.bass * 1.15,
               frame.time - lastBass > 0.14 {
                candidate = .kick
            } else if frame.mid > midThreshold,
                      frame.mid > previous.mid * 1.2,
                      frame.time - lastMid > 0.12 {
                candidate = .snare
            } else if frame.high > highThreshold,
                      frame.high > previous.high * 1.2,
                      frame.time - lastHigh > 0.10 {
                candidate = .hat
            }

            guard let kind = candidate, frame.time - lastAny >= 0.125 else { continue }

            switch kind {
            case .kick: lastBass = frame.time
            case .snare: lastMid = frame.time
            case .hat: lastHigh = frame.time
            }
            lastAny = frame.time
            result.append(BeatEvent(time: frame.time, kind: kind))
        }

        return result
    }

    private static func analyse(
        _ samples: [Float],
        window: [Float],
        setup: FFTSetup,
        log2n: vDSP_Length,
        bassRange: ClosedRange<Int>,
        midRange: ClosedRange<Int>,
        highRange: ClosedRange<Int>
    ) -> (Float, Float, Float)? {
        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        var real = [Float](repeating: 0, count: fftSize / 2)
        var imag = [Float](repeating: 0, count: fftSize / 2)
        var magnitudes = [Float](repeating: 0, count: fftSize / 2)

        real.withUnsafeMutableBufferPointer { realBuffer in
            imag.withUnsafeMutableBufferPointer { imagBuffer in
                guard let realBase = realBuffer.baseAddress,
                      let imagBase = imagBuffer.baseAddress
                else { return }

                var split = DSPSplitComplex(realp: realBase, imagp: imagBase)

                windowed.withUnsafeBufferPointer { sampleBuffer in
                    sampleBuffer.baseAddress?.withMemoryRebound(
                        to: DSPComplex.self,
                        capacity: fftSize / 2
                    ) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                }

                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
            }
        }

        var bass: Float = 0
        var mid: Float = 0
        var high: Float = 0

        for bin in bassRange { bass += magnitudes[bin] }
        for bin in midRange { mid += magnitudes[bin] }
        for bin in highRange { high += magnitudes[bin] }

        // Корень сжимает динамический диапазон: тихая и громкая части трека
        // попадают в один масштаб, порог работает ровнее.
        return (bass.squareRoot(), mid.squareRoot(), high.squareRoot())
    }

    /// Порог = средний уровень первых двух секунд + 2σ. Если начало трека
    /// тише остального, порог всё равно ниже среднего по всему треку.
    private static func threshold(_ values: [Float], times: [Double]) -> Float {
        var window = values
        let calibration = zip(values, times)
            .filter { $0.1 <= 2.0 }
            .map { $0.0 }

        if calibration.count >= 8 {
            window = calibration
        }

        guard !window.isEmpty else { return 0 }

        var sum: Float = 0
        vDSP_sve(window, 1, &sum, vDSP_Length(window.count))
        let mean = sum / Float(window.count)

        var squared = [Float](repeating: 0, count: window.count)
        var offset = -mean
        vDSP_vsadd(window, 1, &offset, &squared, 1, vDSP_Length(window.count))

        var powered = [Float](repeating: 0, count: window.count)
        vDSP_vsq(squared, 1, &powered, 1, vDSP_Length(window.count))

        var squares: Float = 0
        vDSP_sve(powered, 1, &squares, vDSP_Length(window.count))
        let deviation = (squares / Float(window.count)).squareRoot()

        return mean + deviation * 2
    }
}