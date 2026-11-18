import Foundation

/// Реализация «Моей волны» на подтверждённой ручке
/// `GET /rotor/station/{station}/tracks?settings2=true` со станцией
/// `user:onyourwave`.
///
/// Схема ответа сверена с `MarshalX/yandex-music-api` (`StationTracksResult`).
/// Сервер отдаёт `sequence` со элементами `type` = `track`/`ad`; берём только
/// треки. Пустой список считаем ошибкой, а не «нет рекомендаций»: пустая
/// волна у живого аккаунта означает, что мы разобрали ответ не так.
actor YandexRotorProvider: RotorProviding {
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
}
