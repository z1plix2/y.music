import Combine
import Foundation
import OSLog

/// Загрузка экрана альбома.
///
/// `/albums/{id}/with-tracks` отдаёт альбом целиком (треки в `volumes`),
/// поэтому пагинация не нужна.
@MainActor
final class AlbumDetailViewModel: ObservableObject {
    enum State {
        case idle
        case loading
        case loaded(AlbumDetail)
        case failed(APIError)
    }

    @Published private(set) var state: State = .idle

    let albumID: Int

    private let catalog: any MusicCatalogProviding
    private let logger = Logger(subsystem: "com.example.ymusic", category: "AlbumVM")

    init(
        albumID: Int,
        catalog: any MusicCatalogProviding = YandexMusicCatalog.shared
    ) {
        self.albumID = albumID
        self.catalog = catalog
    }

    var album: AlbumDetail? {
        if case .loaded(let album) = state { return album }
        return nil
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
            let album = try await catalog.albumDetail(id: albumID)
            guard !Task.isCancelled else { return }
            state = .loaded(album)
        } catch is CancellationError {
            return
        } catch let error as APIError {
            guard !Task.isCancelled, !error.isCancellation else { return }
            logger.error("Альбом: \(error.localizedDescription, privacy: .public)")
            state = .failed(error)
        } catch {
            guard !Task.isCancelled else { return }
            logger.error("Альбом: \(error.localizedDescription, privacy: .public)")
            state = .failed(.unknown(error.localizedDescription))
        }
    }
}