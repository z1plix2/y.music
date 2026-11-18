import Combine
import Foundation
import OSLog

/// Загрузка экрана артиста.
///
/// Один запрос `/artists/{id}/brief-info` отдаёт и шапку, и популярные
/// треки, и выборку альбомов — отдельной пагинации в этой итерации нет
/// (TODO: `counts.directAlbums` обычно больше, чем пришедших альбомов).
@MainActor
final class ArtistDetailViewModel: ObservableObject {
    enum State {
        case idle
        case loading
        case loaded(ArtistDetail)
        case failed(APIError)
    }

    @Published private(set) var state: State = .idle

    let artistID: Int

    private let catalog: any MusicCatalogProviding
    private let logger = Logger(subsystem: "com.example.ymusic", category: "ArtistVM")

    init(
        artistID: Int,
        catalog: any MusicCatalogProviding = YandexMusicCatalog.shared
    ) {
        self.artistID = artistID
        self.catalog = catalog
    }

    var artist: ArtistDetail? {
        if case .loaded(let artist) = state { return artist }
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
            let artist = try await catalog.artistDetail(id: artistID)
            guard !Task.isCancelled else { return }
            state = .loaded(artist)
        } catch is CancellationError {
            return
        } catch let error as APIError {
            guard !Task.isCancelled, !error.isCancellation else { return }
            logger.error("Артист: \(error.localizedDescription, privacy: .public)")
            state = .failed(error)
        } catch {
            guard !Task.isCancelled else { return }
            logger.error("Артист: \(error.localizedDescription, privacy: .public)")
            state = .failed(.unknown(error.localizedDescription))
        }
    }
}