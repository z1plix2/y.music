import Foundation
import OSLog

/// Разбор XML из `downloadInfoUrl` в части прямой ссылки.
final class DownloadInfoXMLParser: NSObject, XMLParserDelegate {
    private(set) var values: [String: String] = [:]
    private var currentElement: String?

    static func parse(_ data: Data) -> YandexDirectLink.Parts? {
        let delegate = DownloadInfoXMLParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { return nil }

        func value(_ name: String) -> String? {
            guard let raw = delegate.values[name] else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        guard
            let host = value("host"),
            let path = value("path"),
            let ts = value("ts"),
            let signature = value("s")
        else {
            return nil
        }

        return YandexDirectLink.Parts(
            host: host,
            path: path,
            timestamp: ts,
            signature: signature
        )
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard let currentElement else { return }
        values[currentElement, default: ""] += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        currentElement = nil
    }
}

/// Превращает `/download-info` в URL, который играет `AVPlayer`.
///
/// Никакой обход подписки здесь нет: сервер сам решает, какие варианты
/// вернуть. Если вернулся только `preview` — отдаём превью,
/// если не вернулось ничего — `APIError.unavailable`.
actor YandexAudioStreamProvider: AudioStreamProviding {
    static let shared = YandexAudioStreamProvider()

    private let api: APIManager
    private let logger = Logger(subsystem: "com.example.ymusic", category: "AudioStream")

    init(api: APIManager = .shared) {
        self.api = api
    }

    func stream(for track: Track, maxBitrate: Int) async throws -> AudioStream {
        guard track.available else {
            throw APIError.unavailable("Трек недоступен в регионе или удалён из каталога.")
        }

        let infos: [DownloadInfo]
        do {
            infos = try await api.downloadInfo(
                trackID: track.id,
                albumID: track.albums?.first?.id
            )
        } catch let error as APIError {
            if case .http(let status, _) = error, status == 403 || status == 404 {
                throw APIError.unavailable(
                    "Сервер не выдал поток для этого трека — обычно это значит, что он доступен только с Plus."
                )
            }
            throw error
        }
        let usable = infos.filter { !$0.downloadInfoUrl.isEmpty }

        guard !usable.isEmpty else {
            throw APIError.unavailable(
                "Яндекс не предложил ни одного варианта потока — обычно это значит, что трек доступен только с Plus."
            )
        }

        let full = usable.filter { !$0.preview && $0.bitrateInKbps <= maxBitrate }
        if let best = preferred(full) {
            return .full(try await resolve(best))
        }

        if let preview = preferred(usable.filter(\.preview)) {
            return .preview(try await resolve(preview))
        }

        throw APIError.unavailable(
            "Полный трек требует подписки Plus, а превью сервер не вернул."
        )
    }

    // MARK: - Внутреннее

    /// mp3 надёжнее всего играется AVPlayer; при равном кодеке берём больший битрейт.
    private func preferred(_ infos: [DownloadInfo]) -> DownloadInfo? {
        infos.sorted { lhs, rhs in
            if lhs.codec != rhs.codec {
                return lhs.codec == "mp3"
            }
            return lhs.bitrateInKbps > rhs.bitrateInKbps
        }.first
    }

    private func resolve(_ info: DownloadInfo) async throws -> URL {
        if info.direct, let direct = URL(string: info.downloadInfoUrl) {
            return direct
        }

        guard let xmlURL = URL(string: info.downloadInfoUrl) else {
            throw APIError.unavailable("Сервер вернул некорректный адрес потока.")
        }

        let data: Data
        do {
            var request = URLRequest(url: xmlURL)
            request.timeoutInterval = 15
            let (payload, response) = try await URLSession.shared.data(for: request)

            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw APIError.http(status: http.statusCode, payload: nil)
            }
            data = payload
        } catch let error as APIError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw APIError.cancelled
        } catch let error as URLError {
            throw APIError.transport(error)
        }

        guard
            let parts = DownloadInfoXMLParser.parse(data),
            let directURL = YandexDirectLink.url(from: parts)
        else {
            logger.error("Не удалось разобрать XML прямой ссылки")
            throw APIError.unavailable("Не удалось собрать прямую ссылку из ответа сервера.")
        }

        return directURL
    }
}
