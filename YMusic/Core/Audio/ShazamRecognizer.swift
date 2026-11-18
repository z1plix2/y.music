import AVFoundation
import Combine
import Foundation
import OSLog
import ShazamKit

/// Распознавание музыки вокруг через ShazamKit.
///
/// Микрофон читается `AVAudioEngine`, буферы уходят в `SHSession`
/// (`matchStreamingBuffer`) — это документированный путь для живой записи,
/// без ручной сборки `SHSignature`. Состоянием владеет только главный
/// исполнитель; колбэки Shazam приходят на своём потоке и пробрасываются сюда.
///
/// Важно: на симуляторе микрофон может не отдавать звук — проверять
/// на устройстве.
@MainActor
final class ShazamRecognizer: NSObject, ObservableObject {
    /// Найденная песня в терминах интерфейса: `SHMediaItem` не `Equatable`
    /// и живёт только внутри ShazamKit.
    struct Match: Equatable {
        let title: String
        let artist: String
        let artworkURL: URL?
    }

    enum State: Equatable {
        case idle
        case listening
        case found(Match)
        case notFound
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private let logger = Logger(subsystem: "com.example.ymusic", category: "Shazam")
    private let engine = AVAudioEngine()
    private var session: SHSession?
    private var timeoutTask: Task<Void, Never>?
    private var isRunning = false

    /// Сколько слушаем до честного «не распознано».
    private static let listenTimeout: UInt64 = 15_000_000_000

    func start() async {
        guard !isRunning else { return }

        state = .listening
        timeoutTask?.cancel()

        do {
            let granted = await requestMicrophoneAccess()
            guard granted else {
                state = .failed("Нет доступа к микрофону. Разрешите его в настройках iOS.")
                return
            }

            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try audioSession.setActive(true)

            let newSession = SHSession()
            newSession.delegate = self
            session = newSession

            let input = engine.inputNode
            let format = input.inputFormat(forBus: 0)
            guard format.sampleRate > 0 else {
                throw NSError(
                    domain: "com.example.ymusic.shazam",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Микрофон недоступен"]
                )
            }

            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
                // Буфер приходит на аудиопотоке; SHSession потокобезопасен,
                // но отправку помечаем явно, чтобы не держать ссылку на self
                // в аудио-колбэке дольше одного матча.
                Task { @MainActor [weak self] in
                    self?.session?.matchStreamingBuffer(buffer, at: nil)
                }
            }

            engine.prepare()
            try engine.start()
            isRunning = true

            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.listenTimeout)
                guard !Task.isCancelled else { return }
                self?.handleTimeout()
            }
        } catch {
            logger.error("Старт Shazam: \(error.localizedDescription, privacy: .public)")
            stopAudio()
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        timeoutTask?.cancel()
        timeoutTask = nil
        stopAudio()
        if case .listening = state {
            state = .idle
        }
    }

    func reset() {
        stop()
        state = .idle
    }

    // MARK: - Приватное

    private func handleTimeout() {
        guard case .listening = state else { return }
        stopAudio()
        state = .notFound
    }

    private func stopAudio() {
        isRunning = false

        if engine.isRunning {
            engine.stop()
        }
        engine.inputNode.removeTap(onBus: 0)

        session?.delegate = nil
        session = nil

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            logger.debug("Микрофон: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func requestMicrophoneAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func handleMatch(_ item: SHMediaItem?) {
        guard case .listening = state else { return }

        timeoutTask?.cancel()
        timeoutTask = nil
        stopAudio()

        guard let item else {
            state = .notFound
            return
        }

        state = .found(
            Match(
                title: item.title ?? "Неизвестный трек",
                artist: item.artist ?? "",
                artworkURL: item.artworkURL
            )
        )
    }

    private func handleNoMatch(_ error: Error?) {
        guard case .listening = state else { return }

        // Штатное «не нашли» приходит без ошибки; ошибку показываем отдельно.
        if let error {
            logger.error("Shazam: \(error.localizedDescription, privacy: .public)")
            timeoutTask?.cancel()
            timeoutTask = nil
            stopAudio()
            state = .failed(error.localizedDescription)
        }
    }
}

// MARK: - SHSessionDelegate

extension ShazamRecognizer: SHSessionDelegate {
    nonisolated func session(_ session: SHSession, didFind match: SHMatch) {
        let first = match.mediaItems.first
        Task { @MainActor [weak self] in
            self?.handleMatch(first)
        }
    }

    nonisolated func session(
        _ session: SHSession,
        didNotFindMatchFor signature: SHSignature,
        error: Error?
    ) {
        Task { @MainActor [weak self] in
            self?.handleNoMatch(error)
        }
    }
}