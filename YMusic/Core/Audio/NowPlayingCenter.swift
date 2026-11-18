import Foundation
import MediaPlayer
import OSLog
import UIKit

/// Интеграция с системой: локскрин, Control Center, AirPods, CarPlay-кнопки.
///
/// Всё, что относится к `MPNowPlayingInfoCenter` и `MPRemoteCommandCenter`,
/// живёт здесь — `AudioPlayer` остаётся про звук. Обработчики команд
/// возвращают `.success` сразу, а работа уходит в `MainActor`: remote-события
/// приходят не гарантированно на главном потоке.
@MainActor
final class NowPlayingCenter {
    private let logger = Logger(subsystem: "com.example.ymusic", category: "NowPlaying")

    var onPlay: (() -> Bool)?
    var onPause: (() -> Bool)?
    var onTogglePlayPause: (() -> Bool)?
    var onNext: (() -> Bool)?
    var onPrevious: (() -> Bool)?
    var onSeek: ((Double) -> Bool)?
    var onChangeRate: ((Double) -> Bool)?

    private var targets: [(command: MPRemoteCommand, token: Any)] = []
    private var artworkTask: Task<Void, Never>?

    private var artwork: MPMediaItemArtwork?
    private var artworkKey: String?
    private var lastTrack: Track?
    private var lastElapsed: Double = 0
    private var lastDuration: Double = 0
    private var lastIsPlaying = false

    private var center: MPRemoteCommandCenter { .shared() }
    private var infoCenter: MPNowPlayingInfoCenter { .default() }

    // MARK: - Установка

    /// Идемпотентно: повторный вызов после `teardown()` заново подключает
    /// remote-таргеты. Состояние команд (`isEnabled`) выставляет вызывающий.
    func install() {
        installTargets()
    }

    private func installTargets() {
        guard targets.isEmpty else { return }

        add(center.playCommand) { [weak self] in self?.onPlay?() ?? false }
        add(center.pauseCommand) { [weak self] in self?.onPause?() ?? false }
        add(center.togglePlayPauseCommand) { [weak self] in self?.onTogglePlayPause?() ?? false }
        add(center.nextTrackCommand) { [weak self] in self?.onNext?() ?? false }
        add(center.previousTrackCommand) { [weak self] in self?.onPrevious?() ?? false }

        let seekTarget = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let position = positionEvent.positionTime
            Task { @MainActor in _ = self?.onSeek?(position) }
            return .success
        }
        targets.append((center.changePlaybackPositionCommand, seekTarget))

        center.changePlaybackRateCommand.supportedPlaybackRates = [1.0]
        let rateTarget = center.changePlaybackRateCommand.addTarget { [weak self] event in
            guard let rateEvent = event as? MPChangePlaybackRateCommandEvent else {
                return .commandFailed
            }
            let rate = Double(rateEvent.playbackRate)
            Task { @MainActor in _ = self?.onChangeRate?(rate) }
            return rate == 1.0 ? .success : .commandFailed
        }
        targets.append((center.changePlaybackRateCommand, rateTarget))
    }

    private func add(_ command: MPRemoteCommand, _ action: @escaping () -> Bool) {
        let token = command.addTarget { _ in
            Task { @MainActor in _ = action() }
            return .success
        }
        targets.append((command, token))
    }

    func setCommandsEnabled(_ enabled: Bool) {
        center.playCommand.isEnabled = enabled
        center.pauseCommand.isEnabled = enabled
        center.togglePlayPauseCommand.isEnabled = enabled
        center.nextTrackCommand.isEnabled = enabled
        center.previousTrackCommand.isEnabled = enabled
        center.changePlaybackPositionCommand.isEnabled = enabled
        center.changePlaybackRateCommand.isEnabled = enabled

        if !enabled {
            infoCenter.nowPlayingInfo = nil
            infoCenter.playbackState = .stopped
        }
    }

    // MARK: - Метаданные

    func update(track: Track?, isPlaying: Bool, elapsed: Double, duration: Double) {
        lastTrack = track
        lastIsPlaying = isPlaying
        lastElapsed = max(0, elapsed)
        lastDuration = max(duration, track?.duration ?? 0)

        guard let track else {
            infoCenter.nowPlayingInfo = nil
            return
        }

        let key = track.artworkURL?.absoluteString
        if key != artworkKey {
            artworkKey = key
            artwork = nil
            loadArtwork(for: track.artworkURL)
        }

        publish()
    }

    func clear() {
        artworkTask?.cancel()
        artworkTask = nil
        lastTrack = nil
        artwork = nil
        artworkKey = nil
        infoCenter.nowPlayingInfo = nil
        infoCenter.playbackState = .stopped
    }

    func teardown() {
        for entry in targets {
            entry.command.removeTarget(entry.token)
        }
        targets.removeAll()

        artworkTask?.cancel()
        artworkTask = nil
        clear()
    }

    // MARK: - Внутреннее

    private func publish() {
        guard let track = lastTrack else { return }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artistLine,
            MPMediaItemPropertyPlaybackDuration: lastDuration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: lastElapsed,
            MPNowPlayingInfoPropertyPlaybackRate: lastIsPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            // Явный тип контента: без него некоторые версии iOS показывают
            // карточку без обложки в Control Center.
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]

        if let album = track.albums?.first?.title, !album.isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        if let artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }

        infoCenter.nowPlayingInfo = info
        infoCenter.playbackState = lastIsPlaying ? .playing : .paused
    }

    private func loadArtwork(for url: URL?) {
        artworkTask?.cancel()
        guard let url else { return }

        let key = url.absoluteString

        if let cached = ImageLoader.shared.cachedImage(for: url) {
            applyArtwork(cached, key: key)
            return
        }

        artworkTask = Task { [weak self] in
            let image = await ImageLoader.shared.image(for: url)
            guard !Task.isCancelled, let image else { return }
            self?.applyArtwork(image, key: key)
        }
    }

    private func applyArtwork(_ image: UIImage, key: String) {
        guard key == artworkKey, lastTrack != nil else { return }
        artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        publish()
    }
}
