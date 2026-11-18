import Foundation

/// Реализация «Моей волны»: превью — на ручке станции, воспроизведение —
/// на сессиях радио.
///
/// Схема ответов сверена с `MarshalX/yandex-music-api`
/// (`RotorSession` / `RotorSessionTracks` / `SessionEvent`). Сервер отдаёт
/// `sequence` со элементами `type` = `track`/`ad`; берём только треки.
/// Пустой список считаем ошибкой, а не «нет рекомендаций»: пустая волна
/// у живого аккаунта означает, что мы разобрали ответ не так.
actor YandexRotorProvider: RotorProviding, RotorSessionProviding {
    static let shared = YandexRotorProvider()

    /// Станция персональной волны. Именно в таком виде её ждёт ротор.
    static let waveStation = "user:onyourwave"

    /// Заголовок из открытого клиента (`MarshalX/yandex-music-api`,
    /// `utils/request_base.py`). Сервер может требовать конкретную версию
    /// клиента и на незнакомую ответить 400.
    ///
    /// TODO: сверить значение на живом API и заменить на актуальную версию.
    static let clientHeaderValue = "YandexMusicAndroid/24023621"

    private let api: APIManager

    init(api: APIManager = .shared) {
        self.api = api
    }

    func waveTracks(limit: Int) async throws -> [Track] {
        let result = try await api.rotorStationTracks(
            station: Self.waveStation,
            clientHeaderValue: Self.clientHeaderValue
        )

        let tracks = result.tracks
        guard !tracks.isEmpty else {
            throw APIError.unavailable("Ротор не вернул ни одного трека")
        }
        return Array(tracks.prefix(max(1, limit)))
    }

    // MARK: - Сессии радио

    func startSession(seeds: [String], trackToStartFrom: String?) async throws -> RotorSessionStart {
        let session = try await api.rotorSessionNew(
            seeds: seeds,
            trackToStartFrom: trackToStartFrom,
            clientHeaderValue: Self.clientHeaderValue
        )
        guard session.radioSessionId != nil, !session.tracks.isEmpty else {
            throw APIError.unavailable("Ротор не вернул треки сессии")
        }
        return session
    }

    func nextTracks(sessionID: String, queue: [String]) async throws -> RotorSessionBatch {
        try await api.rotorSessionTracks(
            sessionID: sessionID,
            queue: queue,
            clientHeaderValue: Self.clientHeaderValue
        )
    }

    func sendFeedback(
        sessionID: String,
        type: RotorFeedbackType,
        trackID: String?,
        seconds: Double?,
        batchID: String?
    ) async throws {
        try await api.rotorSessionFeedback(
            sessionID: sessionID,
            type: type,
            trackID: trackID,
            seconds: seconds,
            batchID: batchID,
            clientHeaderValue: Self.clientHeaderValue
        )
    }
}