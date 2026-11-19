import Combine
import Foundation
import OSLog

/// Загрузка и редактирование одного плейлиста.
///
/// `/users/{uid}/playlists/{kind}` отдаёт плейлист целиком с массивом
/// `tracks`; пагинация не нужна. Изменения (переименование, удаление,
/// перестановка) идут отдельными ручками с `revision`; после каждой операции
/// список перезапрашивается — так состояние всегда совпадает с сервером.
@MainActor
final class PlaylistDetailViewModel: ObservableObject {
    enum State {
        case idle
        case loading
        case loaded([Track])
        case failed(APIError)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var title: String
    @Published private(set) var isMutating = false
    @Published var mutationError: APIError?

    let playlist: Playlist

    private let userID: Int
    private let catalog: any MusicCatalogProviding
    private let editor: any PlaylistEditingProviding
    private let logger = Logger(subsystem: "com.example.ymusic", category: "PlaylistVM")

    private(set) var total = 0
    private(set) var isTruncated = false
    /// Версия для изменяющих запросов. `nil` — сервер её не отдал,
    /// редактирование недоступно, пока не подскажем пользователю.
    private(set) var revision: Int?

    init(
        playlist: Playlist,
        userID: Int,
        catalog: any MusicCatalogProviding = YandexMusicCatalog.shared,
        editor: any PlaylistEditingProviding = YandexPlaylistEditor.shared
    ) {
        self.playlist = playlist
        self.userID = userID
        self.catalog = catalog
        self.editor = editor
        self.title = playlist.title
        self.revision = playlist.revision
    }

    var tracks: [Track] {
        if case .loaded(let tracks) = state { return tracks }
        return []
    }

    var canEdit: Bool { revision != nil }

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
            apply(page)
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

    private func apply(_ page: PlaylistTracks) {
        total = page.total
        isTruncated = page.isTruncated
        if let revision = page.revision {
            self.revision = revision
        }
    }

    // MARK: - Изменения

    func rename(to newTitle: String) async {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != title else { return }

        let previous = title
        title = trimmed
        await mutate {
            try await self.editor.renamePlaylist(
                userID: self.userID,
                kind: self.playlist.kind,
                title: trimmed
            )
        } rollback: {
            self.title = previous
        }
    }

    func remove(at index: Int) async {
        guard tracks.indices.contains(index),
              let revision = revision
        else { return }

        let original = tracks
        let track = original[index]
        var optimistic = original
        optimistic.remove(at: index)
        state = .loaded(optimistic)

        await mutate {
            try await self.editor.removeFromPlaylist(
                userID: self.userID,
                kind: self.playlist.kind,
                track: track,
                revision: revision
            )
        } rollback: {
            self.state = .loaded(original)
        }
    }

    func move(from source: Int, to destination: Int) async {
        guard let revision = revision,
              tracks.indices.contains(source)
        else { return }

        let original = tracks
        var reordered = original
        let moved = reordered.remove(at: source)
        let insertAt = min(max(destination, 0), reordered.count)
        reordered.insert(moved, at: insertAt)
        state = .loaded(reordered)

        await mutate {
            try await self.editor.moveInPlaylist(
                userID: self.userID,
                kind: self.playlist.kind,
                from: source,
                to: insertAt,
                revision: revision
            )
        } rollback: {
            self.state = .loaded(original)
        }
    }

    /// Общая обёртка: показывает прогресс, ловит ошибку, на успехе
    /// перезапрашивает список (свежий `revision` и порядок).
    private func mutate(
        _ operation: @escaping () async throws -> Void,
        rollback: @escaping () async -> Void
    ) async {
        guard !isMutating else { return }
        isMutating = true
        defer { isMutating = false }

        do {
            try await operation()
            await reload()
        } catch is CancellationError {
            await rollback()
        } catch let error as APIError {
            guard !error.isCancellation else {
                await rollback()
                return
            }
            logger.error("Плейлист, правка: \(error.localizedDescription, privacy: .public)")
            mutationError = error
            await rollback()
        } catch {
            logger.error("Плейлист, правка: \(error.localizedDescription, privacy: .public)")
            mutationError = .unknown(error.localizedDescription)
            await rollback()
        }
    }

    /// Перезапрос без перехода в `.loading`: список не должен мигать.
    private func reload() async {
        do {
            let page = try await catalog.playlistTracks(userID: userID, kind: playlist.kind)
            guard !Task.isCancelled else { return }
            apply(page)
            state = .loaded(page.tracks)
        } catch {
            logger.error("Плейлист, перезапрос: \(error.localizedDescription, privacy: .public)")
        }
    }
}
