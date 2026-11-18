import Combine
import Foundation
import OSLog

/// Загрузка треков одного плейлиста.
///
/// `/users/{uid}/playlists/{kind}` отдаёт плейлист целиком с массивом
/// `tracks`; пагинация не нужна. Если сервер начнёт отдавать усечённый
/// список, здесь появится догрузка по `track-positions` (см. TODO в README).
@MainActor
final class PlaylistDetailViewModel: ObservableObject {
    enum State {
        case idle
        case loading
        case loaded([Track])
        case failed(APIError)
    }

    @Published private(set) var state: State = .idle

    let playlist: Playlist

    private let userID: Int
    private let catalog: any MusicCatalogProviding
    private let logger = Logger(subsystem: "com.example.ymusic", category: "PlaylistVM")

    private(set) var total = 0
    private(set) var isTruncated = false

    init(
        playlist: Playlist,
        userID: Int,
        catalog: any MusicCatalogProviding = YandexMusicCatalog.shared
    ) {
        self.playlist = playlist
        self.userID = userID
        self.catalog = catalog
    }

    var tracks: [Track] {
        if case .loaded(let tracks) = state { return tracks }
        return []
    }

    func loadIfNeeded() async {
        guard case .idle = state else { return }
        await load()
    }

    func retry() async {
        await load()
    }

    private func load() async {
        state = .loading

        do {
            let page = try await catalog.playlistTracks(userID: userID, kind: playlist.kind)
            guard !Task.isCancelled else { return }
            total = page.total
            isTruncated = page.isTruncated
            state = .loaded(page.tracks)
        } catch is CancellationError {
            return
        } catch let error as APIError {
            guard !Task.isCancelled, !error.isCancellation else { return }
            logger.error("Плейлист: \(error.localizedDescription, privacy: .public)")
            state = .failed(error)
        } catch {
            guard !Task.isCancelled else { return }
            logger.error("Плейлист: \(error.localizedDescription, privacy: .public)")
            state = .failed(.unknown(error.localizedDescription))
        }
    }
}
