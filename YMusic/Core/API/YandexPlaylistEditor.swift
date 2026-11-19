import Foundation

/// Реализация редактирования на проверенных ручках Яндекс.API:
/// - `POST /users/{uid}/playlists/create`
/// - `POST /users/{uid}/playlists/{kind}/name`
/// - `POST /users/{uid}/playlists/{kind}/tracks/add`
/// - `POST /users/{uid}/playlists/{kind}/tracks/delete`
/// - `POST /users/{uid}/playlists/{kind}/tracks/move`
///
/// Ответы на изменения сервер отдаёт в разных формах, поэтому здесь только
/// отправка; актуальные треки и `revision` экран перезапрашивает сам.
actor YandexPlaylistEditor: PlaylistEditingProviding {
    static let shared = YandexPlaylistEditor()

    private let api: APIManager

    init(api: APIManager = .shared) {
        self.api = api
    }

    func createPlaylist(userID: Int, title: String) async throws -> Playlist {
        try await api.createPlaylist(userID: userID, title: title)
    }

    func renamePlaylist(userID: Int, kind: Int, title: String) async throws {
        try await api.renamePlaylist(userID: userID, kind: kind, title: title)
    }

    func addToPlaylist(
        userID: Int,
        kind: Int,
        tracks: [Track],
        revision: Int
    ) async throws {
        try await api.addPlaylistTracks(
            userID: userID,
            kind: kind,
            identifiers: tracks.map(Self.identifier),
            revision: revision
        )
    }

    func removeFromPlaylist(
        userID: Int,
        kind: Int,
        track: Track,
        revision: Int
    ) async throws {
        try await api.removePlaylistTracks(
            userID: userID,
            kind: kind,
            identifiers: [Self.identifier(track)],
            revision: revision
        )
    }

    func moveInPlaylist(
        userID: Int,
        kind: Int,
        from: Int,
        to: Int,
        revision: Int
    ) async throws {
        try await api.movePlaylistTrack(
            userID: userID,
            kind: kind,
            from: from,
            to: to,
            revision: revision
        )
    }

    /// Канонический идентификатор: `trackId` или `trackId:albumId`.
    /// С альбомом сервер точнее определяет версию трека.
    private static func identifier(_ track: Track) -> String {
        guard let albumID = track.albums?.first?.id, albumID > 0 else {
            return String(track.id)
        }
        return "\(track.id):\(albumID)"
    }
}
