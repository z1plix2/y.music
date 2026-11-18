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

    /// `/account/status` — единственный ответ, где есть числовой `uid`.
    /// `/account/about` его больше не отдаёт (только `publicId`).
    func accountAbout() async throws -> Account {
        let status = try await client.send(Endpoint(path: "account/status"), as: AccountStatus.self)
        return Account(status: status)
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

    // MARK: - Артисты и альбомы

    /// `GET /artists/{id}/brief-info` — единственная ручка, которая отдаёт
    /// имя, аватар, счётчики, популярные треки и альбомы одним запросом.
    /// `GET /artists/{id}` в API нет (есть `POST /artists` и набор
    /// `/artists/{id}/...`), поэтому не выдумываем путь.
    func artistDetail(id: Int) async throws -> ArtistDetail {
        let response = try await client.send(
            Endpoint(path: "artists/\(id)/brief-info"),
            as: ArtistBriefInfo.self
        )
        guard let artist = response.artist else { throw APIError.missingResult }

        return ArtistDetail(
            id: artist.id ?? id,
            name: artist.name ?? "Неизвестный исполнитель",
            // cover.uri — шаблон без схемы и с `%%`; Artwork.url делает URL.
            avatarURL: Artwork.url(from: artist.cover?.uri),
            counts: artist.counts.map {
                ArtistDetail.Counts(
                    tracks: $0.tracks,
                    directAlbums: $0.directAlbums,
                    alsoAlbums: $0.alsoAlbums,
                    alsoTracks: $0.alsoTracks
                )
            },
            // Сервер отдаёт до 10 популярных треков и выборку альбомов —
            // это не полная дискография, счётчики в UI отдельные.
            popularTracks: response.popularTracks ?? [],
            albums: response.albums ?? []
        )
    }

    /// `GET /albums/{id}/with-tracks` — альбом с треками.
    /// Треки лежат не в `tracks`, а в `volumes` (массив «сторон»); склеиваем
    /// в порядке томов.
    func albumDetail(id: Int) async throws -> AlbumDetail {
        let album = try await client.send(
            Endpoint(path: "albums/\(id)/with-tracks"),
            as: AlbumWithTracks.self
        )
        let tracks = (album.volumes ?? []).flatMap { $0 }.compactMap { $0 }

        return AlbumDetail(
            id: album.id ?? id,
            title: album.title ?? "Без названия",
            year: album.year,
            trackCount: album.trackCount,
            artworkURL: Artwork.url(from: album.coverUri),
            artists: album.artists ?? [],
            tracks: tracks
        )
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

    // MARK: - Сессии ротора

    /// `POST /rotor/session/new` — бесконечная волна партиями.
    /// Тело: `{"seeds": [...], "trackToStartFrom": "id:albumId"}`.
    func rotorSessionNew(
        seeds: [String],
        trackToStartFrom: String?,
        clientHeaderValue: String
    ) async throws -> RotorSessionStart {
        var body: [String: Any] = ["seeds": seeds]
        if let trackToStartFrom {
            body["trackToStartFrom"] = trackToStartFrom
        }

        return try await client.send(
            Endpoint.jsonObject(
                "rotor/session/new",
                body: body,
                headers: ["X-Yandex-Music-Client": clientHeaderValue]
            ),
            as: RotorSessionStart.self
        )
    }

    /// `POST /rotor/session/{id}/tracks` — следующая партия.
    /// `queue` — уже сыгранные треки (`id` или `id:albumId`), чтобы не повторялись.
    func rotorSessionTracks(
        sessionID: String,
        queue: [String],
        clientHeaderValue: String
    ) async throws -> RotorSessionBatch {
        try await client.send(
            Endpoint.jsonObject(
                "rotor/session/\(sessionID)/tracks",
                body: ["queue": queue],
                headers: ["X-Yandex-Music-Client": clientHeaderValue]
            ),
            as: RotorSessionBatch.self
        )
    }

    /// `POST /rotor/session/{id}/feedback` — событие прослушивания.
    ///
    /// Тело: `{"event": {"type": ..., "timestamp": ..., "trackId": ...,
    /// "totalPlayedSeconds": ...}, "batchId": ...}`. Ключи camelCase —
    /// так их сериализует клиент в `MarshalX/yandex-music-api`
    /// (`to_dict(for_request: true)`).
    func rotorSessionFeedback(
        sessionID: String,
        type: RotorFeedbackType,
        trackID: String?,
        seconds: Double?,
        batchID: String?,
        clientHeaderValue: String
    ) async throws {
        var event: [String: Any] = [
            "type": type.rawValue,
            "timestamp": Self.isoTimestamp()
        ]
        if let trackID {
            event["trackId"] = trackID
        }
        if let seconds {
            event["totalPlayedSeconds"] = seconds
        }

        var body: [String: Any] = ["event": event]
        if let batchID {
            body["batchId"] = batchID
        }

        try await client.sendIgnoringResponse(
            Endpoint.jsonObject(
                "rotor/session/\(sessionID)/feedback",
                body: body,
                headers: ["X-Yandex-Music-Client": clientHeaderValue]
            )
        )
    }

    /// Время события — ISO 8601 с миллисекундами, как в примере библиотеки
    /// (`2024-01-01T12:00:00.000Z`). Форматтер создаётся на вызов: он не
    /// потокобезопасен, а держать его в общем состоянии незачем.
    private static func isoTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
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

/// Ответ `GET /artists/{id}/brief-info`.
///
/// Живой ответ (Noize MC, `/artists/160970/brief-info`): `artist.id` —
/// строка, `artist.counts` — числа, `popularTracks` — обычные `Track`,
/// `albums` — обычные `Album`. `artist` может отсутствовать — тогда
/// `APIManager` отдаёт `.missingResult`, а не пустой экран.
struct ArtistBriefInfo: Decodable {
    struct ArtistSummary: Decodable {
        let id: Int?
        let name: String?
        let cover: Artist.Cover?
        let counts: Counts?

        enum CodingKeys: String, CodingKey {
            case id, name, cover, counts
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = container.decodeFlexibleIntIfPresent(forKey: .id)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            cover = try container.decodeIfPresent(Artist.Cover.self, forKey: .cover)
            counts = try container.decodeIfPresent(Counts.self, forKey: .counts)
        }
    }

    struct Counts: Decodable {
        let tracks: Int
        let directAlbums: Int
        let alsoAlbums: Int
        let alsoTracks: Int

        enum CodingKeys: String, CodingKey {
            case tracks, directAlbums, alsoAlbums, alsoTracks
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            tracks = container.decodeFlexibleIntIfPresent(forKey: .tracks) ?? 0
            directAlbums = container.decodeFlexibleIntIfPresent(forKey: .directAlbums) ?? 0
            alsoAlbums = container.decodeFlexibleIntIfPresent(forKey: .alsoAlbums) ?? 0
            alsoTracks = container.decodeFlexibleIntIfPresent(forKey: .alsoTracks) ?? 0
        }
    }

    let artist: ArtistSummary?
    let popularTracks: [Track]?
    let albums: [Album]?
}

/// Ответ `GET /albums/{id}/with-tracks`.
///
/// Верхнеуровневого `tracks` у альбома нет: треки лежат в `volumes`
/// (`[[Track]]`), причём элемент массива в теории может быть `null` —
/// поэтому опционален и сам трек, и весь `volumes`.
struct AlbumWithTracks: Decodable {
    let id: Int?
    let title: String?
    let year: Int?
    let trackCount: Int?
    let coverUri: String?
    let artists: [Artist]?
    let volumes: [[Track?]]?

    enum CodingKeys: String, CodingKey {
        case id, title, year, trackCount, coverUri, artists, volumes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.decodeFlexibleIntIfPresent(forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        year = container.decodeFlexibleIntIfPresent(forKey: .year)
        trackCount = container.decodeFlexibleIntIfPresent(forKey: .trackCount)
        coverUri = try container.decodeIfPresent(String.self, forKey: .coverUri)
        artists = try container.decodeIfPresent([Artist].self, forKey: .artists)
        volumes = try container.decodeIfPresent([[Track?]].self, forKey: .volumes)
    }
}
