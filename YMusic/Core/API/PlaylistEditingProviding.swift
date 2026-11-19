import Foundation

/// Изменение плейлистов пользователя. Отдельный протокол от
/// `MusicCatalogProviding`: чтение и запись — разные сценарии, и экрану
/// достаточно подставить редактирующий провайдер в превью.
protocol PlaylistEditingProviding: Sendable {
    func createPlaylist(userID: Int, title: String) async throws -> Playlist

    func renamePlaylist(userID: Int, kind: Int, title: String) async throws

    /// Добавляет треки в конец. `revision` — текущая версия плейлиста.
    func addToPlaylist(
        userID: Int,
        kind: Int,
        tracks: [Track],
        revision: Int
    ) async throws

    func removeFromPlaylist(
        userID: Int,
        kind: Int,
        track: Track,
        revision: Int
    ) async throws

    /// Перестановка внутри списка: `to` — позиция в УЖЕ изменённом списке,
    /// поэтому вью-модель считает её как `SwiftUI` `onMove`.
    func moveInPlaylist(
        userID: Int,
        kind: Int,
        from: Int,
        to: Int,
        revision: Int
    ) async throws
}
