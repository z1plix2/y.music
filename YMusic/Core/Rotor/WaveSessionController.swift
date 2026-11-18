import Combine
import Foundation
import OSLog
import UIKit

/// Бесконечная «Моя волна» поверх сессий ротора.
///
/// Контроллер не владеет звуком: он создаёт сессию, отдаёт партию треков
/// в `AudioPlayer`, догружает следующую, когда очередь подходит к концу,
/// и отправляет обратную связь (`trackStarted` / `trackFinished` / `skip` /
/// `like` / `dislike`). `AudioPlayer` при этом не меняется — только
/// получает метод `extendQueue(with:)` для дописывания партии.
///
/// Событие окончания трека определяется по времени: плеер не публикует
/// «трек доиграл», поэтому при смене трека сравниваем последний известный
/// `currentTime` с длительностью. Разница в пару секунд для рекомендаций
/// не важна.
@MainActor
final class WaveSessionController: ObservableObject {
    @Published private(set) var isStarting = false
    @Published private(set) var isActive = false
    @Published private(set) var failure: APIError?

    @Published var settings: WaveSettings {
        didSet { store.save(settings) }
    }

    private let provider: any RotorSessionProviding
    private let store: WaveSettingsStore
    private let logger = Logger(subsystem: "com.example.ymusic", category: "WaveSession")

    private weak var player: AudioPlayer?
    private var cancellables: Set<AnyCancellable> = []

    private var sessionID: String?
    private var currentBatchID: String?
    private var batchByTrack: [Int: String] = [:]
    private var played: [String] = []

    private var startTask: Task<Void, Never>?
    private var refillTask: Task<Void, Never>?

    /// В фоне волна не начинает сессии, не отправляет фидбэк и грузит
    /// не больше `backgroundTopUpLimit` треков: экономия батареи и трафика,
    /// при этом очередь не обрывается, если трек доиграл с выключенным экраном.
    private var isInBackground = false
    private var lifecycleCancellables: Set<AnyCancellable> = []

    private var lastTrack: Track?
    private var lastTime: Double = 0

    /// Сколько треков остаётся до конца очереди, когда пора просить партию.
    private static let refillThreshold = 3
    /// Сколько треков максимум догружаем из фона.
    private static let backgroundTopUpLimit = 3

    init(
        provider: any RotorSessionProviding = YandexRotorProvider.shared,
        store: WaveSettingsStore = WaveSettingsStore()
    ) {
        self.provider = provider
        self.store = store
        self.settings = store.load()

        NotificationCenter.default
            .publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in self?.enterBackground() }
            .store(in: &lifecycleCancellables)

        NotificationCenter.default
            .publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in self?.enterForeground() }
            .store(in: &lifecycleCancellables)
    }

    // MARK: - Жизненный цикл приложения

    private func enterBackground() {
        guard !isInBackground else { return }
        isInBackground = true

        // Старт сессии и ожидающая догрузка — обычные сетевые запросы,
        // в фоне они не нужны. Лимит догрузки проверяется при следующем
        // `refillIfNeeded()`.
        startTask?.cancel()
        startTask = nil
        isStarting = false
        refillTask?.cancel()
        refillTask = nil
    }

    private func enterForeground() {
        guard isInBackground else { return }
        isInBackground = false

        // В фоне очередь могла опустеть: догружаем сразу, не дожидаясь
        // смены трека.
        refillIfNeeded()
    }

    // MARK: - Подключение к плееру

    /// Подписки на очередь и время. Идемпотентно: повторный вызов с тем же
    /// плеером ничего не дублирует.
    func attach(player: AudioPlayer) {
        guard self.player !== player else { return }
        self.player = player

        cancellables.removeAll()

        player.$queue
            .map { $0.currentTrack }
            .removeDuplicates { lhs, rhs in lhs?.id == rhs?.id }
            .sink { [weak self] track in
                self?.handleTrackChange(track)
            }
            .store(in: &cancellables)

        player.$currentTime
            .sink { [weak self] time in
                self?.lastTime = time
            }
            .store(in: &cancellables)
    }

    // MARK: - Управление

    func start(from track: Track? = nil) {
        guard !isStarting, !isInBackground else { return }

        failure = nil
        isStarting = true
        startTask?.cancel()

        let startFrom = track.map(Self.identifier)

        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                let session = try await self.provider.startSession(
                    seeds: self.settings.seeds,
                    trackToStartFrom: startFrom
                )
                guard let sessionID = session.radioSessionId else {
                    throw APIError.unavailable("Ротор не вернул идентификатор сессии")
                }

                let tracks = session.tracks
                guard !tracks.isEmpty else {
                    throw APIError.unavailable("Ротор не вернул треки сессии")
                }

                self.sessionID = sessionID
                self.currentBatchID = session.batchId
                self.batchByTrack = [:]
                self.played = []
                self.lastTrack = nil
                self.lastTime = 0
                self.isActive = true
                self.isStarting = false

                for track in tracks {
                    self.batchByTrack[track.id] = session.batchId
                }

                self.player?.play(tracks: tracks, startAt: 0)
            } catch is CancellationError {
                self.isStarting = false
            } catch let error as APIError {
                guard !error.isCancellation else {
                    self.isStarting = false
                    return
                }
                self.logger.error("Старт волны: \(error.localizedDescription, privacy: .public)")
                self.failure = error
                self.isStarting = false
            } catch {
                self.logger.error("Старт волны: \(error.localizedDescription, privacy: .public)")
                self.failure = .unknown(error.localizedDescription)
                self.isStarting = false
            }
        }
    }

    /// Дизлайк в сессии: рекомендации перестанут предлагать похожее.
    /// Коллекцию пользователя это не меняет (так устроен ротор).
    func dislike(_ track: Track) {
        guard isActive else { return }
        send(.dislike, track: track, seconds: clampPlayedSeconds(track))
    }

    func like(_ track: Track) {
        guard isActive else { return }
        send(.like, track: track, seconds: nil)
    }

    // MARK: - Смена трека

    private func handleTrackChange(_ track: Track?) {
        guard isActive, sessionID != nil else {
            lastTrack = track
            return
        }

        let previous = lastTrack
        let previousID = previous?.id
        let newID = track?.id

        if let previous, previousID != newID {
            let seconds = clampPlayedSeconds(previous)
            let finished = previous.duration > 0 && seconds >= previous.duration - 3
            send(finished ? .trackFinished : .skip, track: previous, seconds: seconds)
            lastTime = 0
        }

        lastTrack = track

        guard let track else { return }

        played.append(Self.identifier(track))
        if !played.isEmpty, played.count > 200 {
            played.removeFirst(played.count - 200)
        }

        send(.trackStarted, track: track, seconds: nil)
        refillIfNeeded()
    }

    private func clampPlayedSeconds(_ track: Track) -> Double {
        let total = track.duration > 0 ? track.duration : lastTime
        return max(0, min(lastTime, total))
    }

    // MARK: - Догрузка партии

    private func refillIfNeeded() {
        guard
            let player,
            let sessionID,
            refillTask == nil,
            player.queue.upNextCount <= Self.refillThreshold
        else {
            return
        }

        let queue = played
        refillTask = Task { [weak self] in
            guard let self else { return }
            defer { self.refillTask = nil }

            do {
                let batch = try await self.provider.nextTracks(sessionID: sessionID, queue: queue)
                guard !Task.isCancelled, self.sessionID == sessionID else { return }

                if batch.unknownSession == true {
                    self.logger.error("Сессия волны больше не существует")
                    self.isActive = false
                    return
                }

                let tracks = self.isInBackground
                    ? Array(batch.tracks.prefix(Self.backgroundTopUpLimit))
                    : batch.tracks
                guard !tracks.isEmpty else { return }

                self.currentBatchID = batch.batchId ?? self.currentBatchID
                for track in tracks {
                    self.batchByTrack[track.id] = batch.batchId ?? self.currentBatchID
                }
                self.player?.extendQueue(with: tracks)
            } catch is CancellationError {
                return
            } catch let error as APIError {
                guard !error.isCancellation else { return }
                // Ошибку догрузки не показываем карточкой: текущая очередь
                // должна доиграть, а следующая смена трека попробует снова.
                self.logger.error("Партия волны: \(error.localizedDescription, privacy: .public)")
            } catch {
                self.logger.error("Партия волны: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Обратная связь

    private func send(_ type: RotorFeedbackType, track: Track, seconds: Double?) {
        // Фидбэк — сеть: в фоне не отправляем, он не влияет на текущую очередь.
        guard let sessionID, !isInBackground else { return }
        let trackID = Self.identifier(track)
        let batchID = batchByTrack[track.id] ?? currentBatchID

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.provider.sendFeedback(
                    sessionID: sessionID,
                    type: type,
                    trackID: trackID,
                    seconds: seconds,
                    batchID: batchID
                )
            } catch is CancellationError {
                return
            } catch let error as APIError {
                guard !error.isCancellation else { return }
                self.logger.debug("Обратная связь \(type.rawValue): \(error.localizedDescription, privacy: .public)")
            } catch {
                self.logger.debug("Обратная связь \(type.rawValue): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Идентификатор для ручек ротора: `id` или `id:albumId`.
    private static func identifier(_ track: Track) -> String {
        if let albumID = track.albums?.first?.id, albumID > 0 {
            return "\(track.id):\(albumID)"
        }
        return String(track.id)
    }
}