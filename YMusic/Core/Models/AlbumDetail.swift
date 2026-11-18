import Foundation

/// Альбом для `AlbumDetailView`.
///
/// Собирается в `APIManager` из `GET /albums/{id}/with-tracks`. В ответе
/// треки лежат в `result.volumes` (массив «сторон»), отдельного поля
/// `tracks` на верхнем уровне нет — треки склеиваются в порядке томов.
struct AlbumDetail: Codable, Identifiable, Equatable, Sendable {
    let id: Int
    let title: String
    let year: Int?
    let trackCount: Int?
    let artworkURL: URL?
    let artists: [Artist]
    let tracks: [Track]
}