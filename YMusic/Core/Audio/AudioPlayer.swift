import AVFoundation
import Combine
import Foundation
import OSLog

/// Плеер поверх `AVPlayer`.
///
/// Не знает про Яндекс: получает готовый URL от `AudioStreamProviding`.
/// Системная интеграция (локскрин, пульт, прерывания) вынесена в
/// `NowPlayingCenter`, состояние — в `PlaybackStateStore`.
@MainActor
final class AudioPlayer: ObservableObject {
    enum Status {
        case idle
        case preparing
        case playing
        case paused
        case failed(APIError)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var queue = PlaybackQueue()
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var notice: String?
    @Published private(set) var isBuffering = false
    @Published private(set) var recents: [Track] = []

    /// `AVPlayer.volume`, а не системная громкость: iOS не даёт менять
    /// системную без `MPVolumeView`. Хранится, чтобы не терялась между запусками.
    @Published var volume: Float = 1.0 {
        didSet {
            player.volume = min(max(volume, 0), 1)
        }
    }

    var currentTrack: Track? { queue.currentTrack }

    var isPlaying: Bool {
        if case .playing = status { return true }
        return false
    }

    private let streamProvider: any AudioStreamProviding
    private let stateStore: PlaybackStateStore
    private let nowPlaying = NowPlayingCenter()
    private let logger = Logger(subsystem: "com.example.ymusic", category: "AudioPlayer")
    private let player = AVPlayer()
    private let maxBitrate = 320

    /// 60 тиков по 0.5 с = 30 с: период чекпойнта состояния и обновления
    /// elapsed у системы.
    private static let checkpointTicks = 60

    private var userID: Int?
    private var timeObserverToken: Any?
    private var endObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private var itemObservations: [NSKeyValueObservation] = []
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var pendingSeek: Double?
    private var wasPlayingBeforeInterruption = false
    private var tickCount = 0

    init(
        streamProvider: any AudioStreamProviding = YandexAudioStreamProvider.shared,
        stateStore: PlaybackStateStore = .shared
    ) {
        self.streamProvider = streamProvider
        self.stateStore = stateStore

        player.automaticallyWaitsToMinimizeStalling = true
        player.volume = volume

        installNowPlaying()
        installObservers()
    }

    deinit {
        // Только отмена задачи: остальное снимается в teardown(),
        // потому что deinit не изолирован на MainActor.
        loadTask?.cancel()
    }

    // MARK: - Конфигурация

    func configure(userID: Int) {
        // Идемпотентно: `MainView.task` может сработать повторно, а
        // восстановление очереди затрёт текущее воспроизведение.
        guard self.userID != userID else { return }

        self.userID = userID
        recents = stateStore.loadRecents(userID: userID).map(\.track)
        restoreQueue(userID: userID)
    }

    /// Сохранение из `RootView` при уходе в фон.
    func persistNow() {
        persist()
    }

    /// Возврат из фона: `teardown()` снял remote-таргеты, если очередь
    /// успела опустеть, поэтому при непустой очереди ставим их заново.
    func reinstallRemoteIfNeeded() {
        guard !queue.isEmpty else { return }
        nowPlaying.install()
        nowPlaying.setCommandsEnabled(true)
        syncNowPlaying()
    }

    // MARK: - Публичное управление

    func play(track: Track, in tracks: [Track]) {
        let index = tracks.firstIndex(of: track) ?? 0
        queue = PlaybackQueue(
            tracks: tracks,
            startAt: index,
            isShuffled: queue.isShuffled,
            repeatMode: queue.repeatMode
        )
        pendingSeek = nil
        startPlayback()
    }

    func play(tracks: [Track], startAt index: Int) {
        guard !tracks.isEmpty else { return }
        queue = PlaybackQueue(
            tracks: tracks,
            startAt: index,
            isShuffled: queue.isShuffled,
            repeatMode: queue.repeatMode
        )
        pendingSeek = nil
        startPlayback()
    }

    /// Дописывает треки в очередь, не трогая текущий.
    ///
    /// Нужно «Моей волне»: сессия приносит партии, пока играет предыдущая,
    /// поэтому `play` с новой очередью не подходит — он перезапустил бы трек.
    func extendQueue(with tracks: [Track]) {
        guard !tracks.isEmpty else { return }

        let wasEmpty = queue.isEmpty
        queue.append(contentsOf: tracks)
        guard !wasEmpty else {
            startPlayback()
            return
        }
        persist()
    }

    func togglePlayPause() {
        switch status {
        case .playing:
            wasPlayingBeforeInterruption = false
            player.pause()
            status = .paused
            persist()
            syncNowPlaying()
        case .paused:
            if player.currentItem == nil {
                startPlayback()
            } else {
                activateSessionIfNeeded()
                player.play()
                status = .playing
                syncNowPlaying()
            }
        case .idle, .failed:
            startPlayback()
        case .preparing:
            break
        }
    }

    func next() {
        guard queue.advance(by: 1) != nil else { return }
        pendingSeek = nil
        startPlayback()
    }

    func previous() {
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        guard queue.advance(by: -1) != nil else {
            seek(to: 0)
            return
        }
        pendingSeek = nil
        startPlayback()
    }

    func seek(to seconds: Double) {
        let total = max(duration, queue.currentTrack?.duration ?? 0)
        let clamped = min(max(seconds, 0), max(total, 0))
        let target = CMTime(seconds: clamped, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = clamped
        persist()
        syncNowPlaying()
    }

    func toggleShuffle() {
        queue.toggleShuffle()
        persist()
    }

    func cycleRepeat() {
        queue.cycleRepeat()
        persist()
    }

    /// Полная остановка: освобождает сеть, AVPlayerItem, аудиосессию и пульт.
    func stop() {
        teardown()
        resetState()
    }

    func teardown() {
        loadGeneration += 1
        loadTask?.cancel()
        loadTask = nil

        player.pause()
        player.replaceCurrentItem(with: nil)

        if let timeObserverToken {
            player.removeTimeObserver(timeObserverToken)
            self.timeObserverToken = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
        if let routeObserver {
            NotificationCenter.default.removeObserver(routeObserver)
            self.routeObserver = nil
        }

        invalidateItemObservations()
        nowPlaying.teardown()

        deactivateSession()
    }

    /// Выход из аккаунта: teardown() + очистка сохранённого состояния +
    /// пустая очередь. `teardown()` уже чистит `NowPlayingCenter`
    /// (снятие таргетов и `clear()`), поэтому отдельный вызов не нужен.
    func resetForSignOut() {
        stop()
        if let userID {
            stateStore.clear(userID: userID)
        }
        userID = nil
        recents = []
    }

    // MARK: - Восстановление

    private func restoreQueue(userID: Int) {
        guard
            let snapshot = stateStore.load(userID: userID),
            !snapshot.tracks.isEmpty
        else {
            return
        }

        let mode = PlaybackQueue.RepeatMode(rawValue: snapshot.repeatMode) ?? .off
        queue = PlaybackQueue(
            tracks: snapshot.tracks.map(\.track),
            startAt: snapshot.index,
            isShuffled: snapshot.shuffle,
            repeatMode: mode
        )
        pendingSeek = snapshot.position > 0 ? snapshot.position : nil
        currentTime = snapshot.position
        duration = queue.currentTrack?.duration ?? 0
        volume = snapshot.volume
        status = .paused

        syncNowPlaying()
    }

    // MARK: - Загрузка

    private func startPlayback() {
        guard !queue.isEmpty else { return }

        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration

        loadTask = Task { [weak self] in
            await self?.prepareCurrent(generation: generation)
        }
    }

    private func prepareCurrent(generation: Int) async {
        guard let track = queue.currentTrack else {
            status = .idle
            return
        }

        invalidateItemObservations()
        status = .preparing
        isBuffering = true
        currentTime = 0
        duration = track.duration
        notice = nil
        if pendingSeek == nil { persist() }
        syncNowPlaying()

        do {
            let stream = try await streamProvider.stream(for: track, maxBitrate: maxBitrate)
            guard generation == loadGeneration, !Task.isCancelled else { return }

            if case .preview = stream {
                notice = "Без Plus доступно только превью"
            }

            activateSessionIfNeeded()

            let item = AVPlayerItem(url: stream.url)
            item.preferredForwardBufferDuration = 4
            observe(item)

            player.replaceCurrentItem(with: item)
            player.play()
            status = .playing

            if let seekTarget = pendingSeek {
                pendingSeek = nil
                // Явный `completionHandler` берёт синхронную перегрузку:
                // в async-контексте Swift иначе выбирает async-вариант
                // (`seek(...) async -> Bool`) и требует `await`.
                player.seek(
                    to: CMTime(seconds: seekTarget, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero,
                    completionHandler: { _ in }
                )
                currentTime = seekTarget
            }

            recordRecent(track)
            persist()
            syncNowPlaying()
        } catch is CancellationError {
            return
        } catch let error as APIError {
            guard generation == loadGeneration else { return }
            isBuffering = false
            logger.error("Поток: \(error.localizedDescription, privacy: .public)")
            status = .failed(error)
            syncNowPlaying()
        } catch {
            guard generation == loadGeneration else { return }
            isBuffering = false
            logger.error("Поток: \(error.localizedDescription, privacy: .public)")
            status = .failed(.unknown(error.localizedDescription))
            syncNowPlaying()
        }
    }

    private func handleTrackEnded() {
        if queue.repeatMode == .one {
            seek(to: 0)
            player.play()
            status = .playing
            syncNowPlaying()
            return
        }

        guard queue.advance(by: 1) != nil else {
            player.pause()
            seek(to: 0)
            status = .paused
            syncNowPlaying()
            return
        }

        pendingSeek = nil
        startPlayback()
    }

    // MARK: - Наблюдение за AVPlayerItem

    private func observe(_ item: AVPlayerItem) {
        itemObservations = [
            item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
                let state = item.status
                let message = item.error?.localizedDescription
                Task { @MainActor in self?.handleItemStatus(state, message: message) }
            }
        ]
    }

    private func invalidateItemObservations() {
        itemObservations.forEach { $0.invalidate() }
        itemObservations.removeAll()
    }

    private func handleItemStatus(_ state: AVPlayerItem.Status, message: String?) {
        switch state {
        case .readyToPlay:
            isBuffering = false
            if let itemDuration = player.currentItem?.duration,
               itemDuration.isNumeric,
               itemDuration.seconds.isFinite,
               itemDuration.seconds > 0 {
                duration = itemDuration.seconds
            }
            syncNowPlaying()
        case .failed:
            isBuffering = false
            logger.error("AVPlayerItem: \(message ?? "без описания", privacy: .public)")
            status = .failed(.unknown(message ?? "Не удалось воспроизвести трек"))
            syncNowPlaying()
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    private func updateTime(_ time: CMTime) {
        guard time.isNumeric else { return }
        let seconds = time.seconds
        guard seconds.isFinite, seconds >= 0 else { return }
        currentTime = seconds

        if duration <= 0,
           let itemDuration = player.currentItem?.duration,
           itemDuration.isNumeric,
           itemDuration.seconds.isFinite,
           itemDuration.seconds > 0 {
            duration = itemDuration.seconds
        }

        tickCount += 1
        // Тик идёт раз в 0.5 с. Прогресс на локскрине система экстраполирует
        // сама по playbackRate, а `UserDefaults` на каждый тик писать незачем:
        // и то и другое обновляем как чекпойнт раз в 30 с.
        if tickCount % Self.checkpointTicks == 0 {
            syncNowPlaying()
            persist()
        }
    }

    // MARK: - Системная интеграция

    private func installNowPlaying() {
        nowPlaying.onPlay = { [weak self] in self?.remotePlay() ?? false }
        nowPlaying.onPause = { [weak self] in self?.remotePause() ?? false }
        nowPlaying.onTogglePlayPause = { [weak self] in
            self?.togglePlayPause()
            return true
        }
        nowPlaying.onNext = { [weak self] in
            guard let self, !self.queue.isEmpty else { return false }
            self.next()
            return true
        }
        nowPlaying.onPrevious = { [weak self] in
            guard let self, !self.queue.isEmpty else { return false }
            self.previous()
            return true
        }
        nowPlaying.onSeek = { [weak self] position in
            guard let self, self.player.currentItem != nil else { return false }
            self.seek(to: position)
            return true
        }
        nowPlaying.onChangeRate = { rate in
            abs(rate - 1.0) < 0.001
        }
        nowPlaying.install()
        nowPlaying.setCommandsEnabled(false)
    }

    private func syncNowPlaying() {
        // Повторный `install()` безопасен (внутри проверка на пустой список)
        // и нужен после `teardown()`, который снял remote-таргеты:
        // иначе пульт и локскрин перестанут управлять плеером до перезапуска.
        nowPlaying.install()

        let track = queue.currentTrack
        nowPlaying.setCommandsEnabled(!queue.isEmpty)
        guard track != nil else { return }
        nowPlaying.update(
            track: track,
            isPlaying: isPlaying,
            elapsed: currentTime,
            duration: max(duration, track?.duration ?? 0)
        )
    }

    private func remotePlay() -> Bool {
        guard !queue.isEmpty else { return false }
        if !isPlaying {
            wasPlayingBeforeInterruption = false
            if player.currentItem == nil {
                startPlayback()
            } else {
                activateSessionIfNeeded()
                player.play()
                status = .playing
                syncNowPlaying()
            }
        }
        return true
    }

    private func remotePause() -> Bool {
        guard isPlaying else { return true }
        wasPlayingBeforeInterruption = false
        player.pause()
        status = .paused
        persist()
        syncNowPlaying()
        return true
    }

    private func installObservers() {
        let session = AVAudioSession.sharedInstance()

        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in self?.updateTime(time) }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleTrackEnded() }
        }

        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] note in
            let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            Task { @MainActor in
                self?.handleInterruption(typeRaw: typeRaw, optionsRaw: optionsRaw)
            }
        }

        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] note in
            let reasonRaw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in self?.handleRouteChange(reasonRaw: reasonRaw) }
        }
    }

    private func handleInterruption(typeRaw: UInt?, optionsRaw: UInt?) {
        guard
            let typeRaw,
            let type = AVAudioSession.InterruptionType(rawValue: typeRaw)
        else {
            return
        }

        switch type {
        case .began:
            wasPlayingBeforeInterruption = isPlaying
            if isPlaying {
                player.pause()
                status = .paused
                persist()
                syncNowPlaying()
            }

        case .ended:
            let options = optionsRaw
                .map { AVAudioSession.InterruptionOptions(rawValue: $0) } ?? []
            let shouldResume = options.contains(.shouldResume) && wasPlayingBeforeInterruption
            wasPlayingBeforeInterruption = false
            guard shouldResume else { return }

            activateSessionIfNeeded()
            if player.currentItem == nil {
                startPlayback()
            } else {
                player.play()
                status = .playing
                syncNowPlaying()
            }

        @unknown default:
            break
        }
    }

    private func handleRouteChange(reasonRaw: UInt?) {
        guard
            let reasonRaw,
            let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw),
            reason == .oldDeviceUnavailable
        else {
            return
        }

        // Выдернули наушники — пауза без автовозобновления.
        guard isPlaying else { return }
        wasPlayingBeforeInterruption = false
        player.pause()
        status = .paused
        persist()
        syncNowPlaying()
    }

    // MARK: - Persistence

    private func resetState() {
        queue = PlaybackQueue()
        status = .idle
        currentTime = 0
        duration = 0
        notice = nil
        isBuffering = false
        pendingSeek = nil
        nowPlaying.setCommandsEnabled(false)
    }

    private func persist() {
        guard let userID, !queue.isEmpty else { return }
        let currentIndex = queue.currentTrack
            .flatMap { queue.tracks.firstIndex(of: $0) } ?? 0

        let snapshot = StoredPlayback(
            tracks: queue.tracks.map { StoredTrack(track: $0) },
            index: currentIndex,
            position: currentTime,
            shuffle: queue.isShuffled,
            repeatMode: queue.repeatMode.rawValue,
            volume: volume
        )
        stateStore.save(snapshot, userID: userID)
    }

    private func recordRecent(_ track: Track) {
        guard let userID else { return }

        var stored = recents.map { StoredTrack(track: $0) }
        stored.removeAll { $0.id == track.id }
        stored.insert(StoredTrack(track: track), at: 0)
        stored = Array(stored.prefix(20))

        recents = stored.map(\.track)
        stateStore.saveRecents(stored, userID: userID)
    }

    // MARK: - Аудиосессия

    private func activateSessionIfNeeded() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            logger.error("AVAudioSession: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func deactivateSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        } catch {
            logger.debug("AVAudioSession deactivate: \(error.localizedDescription, privacy: .public)")
        }
    }
}
