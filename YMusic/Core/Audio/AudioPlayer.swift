import AVFoundation
import Combine
import Foundation
import OSLog
import WidgetKit

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

    /// Конец сна-таймера; `nil`, если таймер не запущен.
    @Published private(set) var sleepTimerEndsAt: Date?

    /// Профиль известен: `configure(userID:)` уже прошёл. Нужно deep link —
    /// до этого момента восстановление очереди перезаписало бы запуск.
    @Published private(set) var isConfigured = false

    /// `AVPlayer.volume`, а не системная громкость: iOS не даёт менять
    /// системную без `MPVolumeView`. Хранится, чтобы не терялась между запусками.
    @Published var volume: Float = 1.0 {
        didSet {
            player.volume = min(max(volume, 0), 1)
        }
    }

    var currentTrack: Track? { queue.currentTrack }

    /// Для видео-открытки: исходный `AVAsset` без доступа к приватному
    /// `AVPlayer` и позиция, с которой брать 10 секунд.
    var currentExportAsset: AVAsset? { player.currentItem?.asset }

    var isPlaying: Bool {
        if case .playing = status { return true }
        return false
    }

    private let streamProvider: any AudioStreamProviding
    private let stateStore: PlaybackStateStore
    private let nowPlaying = NowPlayingCenter()
    private let logger = Logger(subsystem: "com.example.ymusic", category: "AudioPlayer")
    private let player = AVPlayer()
    /// Качество стрима — из настроек: 320 или 192 кбит/с.
    private var maxBitrate: Int { AppSettingsStore.shared.bitrate }

    /// Вибро в такт: живёт только при включённой настройке и на устройстве
    /// с Taptic Engine. Владелец — плеер, чтобы гасить его вместе с треком.
    private var beatHaptics: BeatHapticsEngine?
    private var currentStreamURL: URL?

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
    private var fadeTask: Task<Void, Never>?
    private var sleepTimerTask: Task<Void, Never>?
    /// Предыдущая позиция из тика: по разнице считаем реально прослушанное.
    private var lastObservedTime: Double = 0

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
        isConfigured = true
        recents = stateStore.loadRecents(userID: userID).map(\.track)
        ListeningStatsStore.shared.configure(userID: userID)
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

        if isPlaying {
            beatHaptics?.resume()
        }
    }

    /// Настройку «Вибрирует в такт» переключили. При включении на играющем
    /// треке движок стартует сразу; при выключении — гасим без ожидания
    /// следующего трека.
    func updateBeatHapticsPreference() {
        guard UserDefaults.standard.bool(forKey: "beatHapticsEnabled") else {
            stopBeatHaptics()
            return
        }

        guard let currentStreamURL, isPlaying else { return }
        startBeatHaptics(for: currentStreamURL)
    }

    // MARK: - Публичное управление

    func play(track: Track, in tracks: [Track]) {
        // Сначала по id: у трека из search/истории могут отличаться поля
        // (duration, albums), и синтезированный Equatable дал бы nil → 0.
        let index = tracks.firstIndex { $0.id == track.id }
            ?? tracks.firstIndex(of: track)
            ?? 0
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

    // MARK: - Управление очередью

    /// Вставляет трек сразу после текущего. Если очередь пуста — просто
    /// кладёт его туда, но не запускает: воспроизведение начинает пользователь.
    func playNext(_ track: Track) {
        queue.insertNext(track)
        logger.info("Трек поставлен следующим: \(track.title, privacy: .public)")
        persist()
    }

    /// Добавляет трек в конец очереди, не трогая текущий.
    func addToQueue(_ track: Track) {
        queue.append(track)
        logger.info("Трек добавлен в очередь: \(track.title, privacy: .public)")
        persist()
    }

    /// Удаляет трек из очереди. Если удалён играющий — запускает следующий.
    func removeFromQueue(at index: Int) {
        guard queue.tracks.indices.contains(index) else { return }

        let removedTrack = queue.tracks[index]
        let wasCurrent = removedTrack.id == queue.currentTrack?.id
        queue.remove(at: index)

        guard wasCurrent else { return }

        if queue.isEmpty {
            stop()
        } else {
            pendingSeek = nil
            startPlayback()
        }
    }

    /// Перестановка в секции «Дальше».
    func moveInQueue(fromOffsets source: IndexSet, toOffset destination: Int) {
        queue.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    /// Очищает очередь. С `keepingCurrent` оставляет только играющий трек.
    func clearQueue(keepingCurrent: Bool) {
        queue.clear(keepingCurrent: keepingCurrent)

        if queue.isEmpty {
            stop()
        } else {
            persist()
        }
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

    /// Плавный переход на следующий трек: громкость уходит в ноль, меняется
    /// элемент, громкость возвращается. Полноценный кроссфейд (два
    /// `AVPlayerItem` одновременно) требует второй плеер и переписывания
    /// `replaceCurrentItem`, поэтому шаг честный: fade out + fade in.
    /// Нужен дизлайку в «Моей волне», но работает для любого `next()`.
    func fadeOutAndNext() {
        guard !queue.isEmpty else { return }

        fadeTask?.cancel()
        let target = volume
        let steps = 8

        fadeTask = Task { [weak self] in
            guard let self else { return }

            for step in 1...steps {
                guard !Task.isCancelled else {
                    self.player.volume = target
                    return
                }
                self.player.volume = target * Float(steps - step) / Float(steps)
                try? await Task.sleep(nanoseconds: 30_000_000)
            }

            self.advanceToNext()

            for step in 1...steps {
                guard !Task.isCancelled else { break }
                self.player.volume = target * Float(step) / Float(steps)
                try? await Task.sleep(nanoseconds: 40_000_000)
            }
            self.player.volume = target
        }
    }

    // MARK: - Сон-таймер

    /// Засыпание: за 30 секунд до конца громкость плавно уходит в ноль,
    /// затем пауза. Громкость возвращается, чтобы утренний запуск не был
    /// беззвучным. `minutes` меньше половины минуты просто не даёт
    /// полноценного затухания — тогда пауза наступает сразу.
    func startSleepTimer(minutes: Int) {
        cancelSleepTimer()
        guard minutes > 0 else { return }

        let endsAt = Date().addingTimeInterval(TimeInterval(minutes * 60))
        sleepTimerEndsAt = endsAt
        let restoreVolume = volume

        sleepTimerTask = Task { [weak self] in
            guard let self else { return }

            let fadeSeconds: TimeInterval = 30
            let delay = max(TimeInterval(minutes * 60) - fadeSeconds, 0)

            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }

            let steps = 30
            for step in 1...steps {
                guard !Task.isCancelled else { return }
                self.player.volume = restoreVolume * Float(steps - step) / Float(steps)
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }
            }

            guard !Task.isCancelled else { return }
            self.player.pause()
            self.status = .paused
            self.beatHaptics?.pause()
            self.player.volume = restoreVolume
            self.sleepTimerEndsAt = nil
            self.sleepTimerTask = nil
            self.persist()
            self.syncNowPlaying()
        }
    }

    func cancelSleepTimer() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        if sleepTimerEndsAt != nil {
            player.volume = volume
        }
        sleepTimerEndsAt = nil
    }

    func togglePlayPause() {
        switch status {
        case .playing:
            wasPlayingBeforeInterruption = false
            player.pause()
            status = .paused
            beatHaptics?.pause()
            persist()
            syncNowPlaying()
        case .paused:
            if player.currentItem == nil {
                startPlayback()
            } else {
                activateSessionIfNeeded()
                player.play()
                status = .playing
                beatHaptics?.resume()
                syncNowPlaying()
            }
        case .idle, .failed:
            startPlayback()
        case .preparing:
            break
        }

        updateWidgetSnapshot()
    }

    func next() {
        // Кроссфейд — опция: при включённой галочке переход идёт через
        // затухание. Отдельный `advanceToNext`, чтобы `fadeOutAndNext`
        // не зациклился сам на себя.
        if AppSettingsStore.shared.crossfadeEnabled, isPlaying, !queue.isEmpty {
            fadeOutAndNext()
            return
        }
        advanceToNext()
    }

    private func advanceToNext() {
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
        updateWidgetSnapshot()
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
        fadeTask?.cancel()
        fadeTask = nil
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerEndsAt = nil

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
        stopBeatHaptics()

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
        isConfigured = false
        recents = []
        ListeningStatsStore.shared.detach()
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
        lastObservedTime = 0
        duration = track.duration
        notice = nil
        if pendingSeek == nil { persist() }
        syncNowPlaying()

        do {
            let stream = try await streamProvider.stream(for: track, maxBitrate: maxBitrate)
            guard generation == loadGeneration, !Task.isCancelled else { return }

            currentStreamURL = stream.url

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

            startBeatHaptics(for: stream.url)

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
            ListeningStatsStore.shared.recordStart(track)
            updateWidgetSnapshot(reload: true)
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
        if let track = queue.currentTrack {
            ListeningStatsStore.shared.recordFinish(track)
        }

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
            beatHaptics?.pause()
            syncNowPlaying()
            updateWidgetSnapshot(reload: true)
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

        // Стрик и часы растут только по реально проигранному времени:
        // разница между тиками, а не фиксированные 0.5 с (после seek она
        // бывает большой, её отбрасываем).
        let delta = seconds - lastObservedTime
        if delta > 0, delta <= 2 {
            ListeningStatsStore.shared.addListeningTime(delta)
        }
        lastObservedTime = seconds

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
            updateWidgetSnapshot()
        }
    }

    // MARK: - Виджет

    /// Снимок для WidgetKit. Обновление таймлайна — только на смене трека
    /// и переходе play/pause: `reloadAllTimelines()` тратит бюджет системы,
    /// а прогресс виджет считает сам от `updatedAt`.
    private func updateWidgetSnapshot(reload: Bool = false) {
        guard let track = queue.currentTrack else {
            WidgetSharedStore.clear()
            if reload {
                WidgetCenter.shared.reloadAllTimelines()
            }
            return
        }

        WidgetSharedStore.save(
            WidgetTrackSnapshot(
                id: track.id,
                title: track.title,
                artist: track.artistLine,
                artworkURLString: track.artworkURL?.absoluteString,
                isPlaying: isPlaying,
                currentTime: currentTime,
                duration: max(duration, track.duration),
                updatedAt: Date()
            )
        )

        if reload {
            WidgetCenter.shared.reloadAllTimelines()
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
                beatHaptics?.resume()
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
        beatHaptics?.pause()
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
                beatHaptics?.pause()
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
                beatHaptics?.resume()
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
        beatHaptics?.pause()
        persist()
        syncNowPlaying()
    }

    // MARK: - Вибро в такт

/// Один движок на трек: анализ стартует параллельно с воспроизведением,
/// а `stopBeatHaptics` удаляет временный файл. При выключенной настройке
/// движок не создаётся вообще — CPU и сеть не тратятся.
private func startBeatHaptics(for url: URL) {
        stopBeatHaptics()

        guard UserDefaults.standard.bool(forKey: "beatHapticsEnabled"),
              BeatHapticsSupport.isSupported
        else {
            return
        }

        let engine = BeatHapticsEngine()
        engine.timeProvider = { [weak self] in
            self?.currentTime ?? 0
        }
        beatHaptics = engine
        engine.start(streamURL: url)
    }

    private func stopBeatHaptics() {
        beatHaptics?.stop()
        beatHaptics = nil
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
        updateWidgetSnapshot(reload: true)
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
