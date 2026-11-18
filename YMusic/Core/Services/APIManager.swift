import Foundation

/// Высокоуровневый фасад над `APIClient`: типизированные методы API.
///
/// Здесь же — единственное место, где мы нормализуем ответы сервера
/// (конверты, строковые id, пачки треков). Прямого доступа к `URLSession`
/// из UI-слоя нет.
///
/// `Sendable`: оба свойства — immutable ссылки на actor'ы (`TokenStore`,
/// `APIClient`), поэтому объект безопасно передавать между исполнителями.
final class APIManager: Sendable {
    static let shared = APIManager()

    let tokens: TokenStore
    private let client: APIClient

    init(
        tokens: TokenStore = .shared,
        baseURL: URL = URL(string: "https://api.music.yandex.net")!
    ) {
        self.tokens = tokens
        self.client = APIClient(baseURL: baseURL, tokens: tokens)
    }

    // MARK: - Состояние

    var isAuthorized: Bool {
        get async { await tokens.hasToken }
    }

    func signOut() async {
        await tokens.signOut()
    }

    // MARK: - Аккаунт

    func accountAbout() async throws -> Account {
        try await client.send(Endpoint(path: "account/about"), as: Account.self)
    }

    // MARK: - Каталог

    func search(text: String, type: String = "all", page: Int = 0) async throws -> SearchResult {
        let endpoint = Endpoint(
            path: "search",
            query: [
                "text": text,
                "type": type,
                "page": String(page),
                "nocorrect": "false"
            ]
        )
        return try await client.send(endpoint, as: SearchResult.self)
    }

    func playlists(userID: Int) async throws -> [Playlist] {
        let response = try await client.send(
            Endpoint(path: "users/\(userID)/playlists/list"),
            as: PlaylistsResponse.self
        )
        return response.playlists
    }

    func playlistTracks(userID: Int, kind: Int) async throws -> PlaylistTracks {
        let endpoint = Endpoint(path: "users/\(userID)/playlists/\(kind)")
        let playlist = try await client.send(endpoint, as: PlaylistWithTracks.self)
        let tracks = playlist.tracks?.compactMap(\.track) ?? []
        // trackCount — поле плейлиста. Если его нет, считаем total равным
        // числу пришедших треков, чтобы не показывать ложную плашку.
        let total = max(playlist.trackCount ?? tracks.count, tracks.count)
        return PlaylistTracks(tracks: tracks, total: total)
    }

    // MARK: - Ротор

    /// `GET /rotor/station/{station}/tracks`. Сервер требует заголовок
    /// `X-Yandex-Music-Client`; значение передаётся вызывающим, чтобы не
    /// размазывать «магическую» версию клиента по коду.
    func rotorStationTracks(station: String, clientHeaderValue: String) async throws -> RotorTracks {
        try await client.send(
            Endpoint(
                path: "rotor/station/\(station)/tracks",
                query: ["settings2": "true"],
                headers: ["X-Yandex-Music-Client": clientHeaderValue]
            ),
            as: RotorTracks.self
        )
    }

    // MARK: - Треки

    /// `/tracks` принимает несколько id за раз: `track-ids=1:2:3`.
    func tracks(ids: [Int]) async throws -> [Track] {
        guard !ids.isEmpty else { return [] }
        let endpoint = Endpoint(
            path: "tracks",
            query: ["track-ids": ids.map(String.init).joined(separator: ":")]
        )
        return try await client.send(endpoint, as: [Track].self)
    }

    /// Канонический id трека для ручек — `trackId` или `trackId:albumId`.
    /// С album id сервер отдаёт более точный вариант (ремастер, версию).
    func downloadInfo(trackID: Int, albumID: Int? = nil) async throws -> [DownloadInfo] {
        let identifier = albumID.map { "\(trackID):\($0)" } ?? String(trackID)
        return try await client.send(
            Endpoint(path: "tracks/\(identifier)/download-info"),
            as: [DownloadInfo].self
        )
    }

    func like(trackID: Int, userID: Int, albumID: Int? = nil) async throws {
        try await client.sendIgnoringResponse(
            Endpoint.form(
                "users/\(userID)/likes/tracks/add-multiple",
                fields: ["track-ids": Self.trackIdentifier(trackID, albumID)]
            )
        )
    }

    func unlike(trackID: Int, userID: Int, albumID: Int? = nil) async throws {
        try await client.sendIgnoringResponse(
            Endpoint.form(
                "users/\(userID)/likes/tracks/remove",
                fields: ["track-ids": Self.trackIdentifier(trackID, albumID)]
            )
        )
    }

    private static func trackIdentifier(_ trackID: Int, _ albumID: Int?) -> String {
        albumID.map { "\(trackID):\($0)" } ?? String(trackID)
    }

    // MARK: - Коллекция

    /// `/likes/tracks` отдаёт только короткие ссылки (id + albumId),
    /// поэтому полный список — это два шага: id, затем пачки `/tracks`.
    func likedTrackIDs(userID: Int) async throws -> [Int] {
        let liked = try await client.send(
            Endpoint(path: "users/\(userID)/likes/tracks"),
            as: LikedTracks.self
        )
        return (liked.library?.tracks ?? []).map(\.id)
    }
}

/// Плейлист с вложенными треками (`/users/{uid}/playlists/{kind}`).
struct PlaylistWithTracks: Decodable {
    struct Item: Decodable {
        let track: Track?
    }

    let uid: Int?
    let kind: Int?
    let title: String?
    /// По этому полю понимаем, отдал ли сервер плейлист целиком.
    let trackCount: Int?
    let tracks: [Item]?

    enum CodingKeys: String, CodingKey {
        case uid, kind, title, trackCount, tracks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uid = container.decodeFlexibleIntIfPresent(forKey: .uid)
        kind = container.decodeFlexibleIntIfPresent(forKey: .kind)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        trackCount = container.decodeFlexibleIntIfPresent(forKey: .trackCount)
        tracks = try container.decodeIfPresent([Item].self, forKey: .tracks)
    }
}
