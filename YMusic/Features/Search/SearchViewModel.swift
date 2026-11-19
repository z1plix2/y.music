import Combine
import Foundation
import OSLog

/// Поиск: дебаунс ввода, отмена предыдущего запроса, история.
///
/// Дебаунс сделан `Task` + `Task.sleep`, а не Combine: так отмена — это
/// `Task.cancel()`, а не отдельная подписка, и код остаётся в одном стиле
/// с остальными вью-моделями.
@MainActor
final class SearchViewModel: ObservableObject {
    enum State {
        case idle
        case loading
        case loaded(SearchResult)
        case failed(APIError)
    }

    /// Быстрый фильтр результата. `apiType` — значение параметра `type`
    /// для ручки `/search`; новых эндпоинтов не заводим.
    enum Filter: String, CaseIterable, Identifiable {
        case all
        case track
        case artist
        case album
        case playlist

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "Всё"
            case .track: return "Треки"
            case .artist: return "Артисты"
            case .album: return "Альбомы"
            case .playlist: return "Плейлисты"
            }
        }

        var apiType: String {
            switch self {
            case .all: return "all"
            case .track: return "track"
            case .artist: return "artist"
            case .album: return "album"
            case .playlist: return "playlist"
            }
        }
    }

    /// Пауза между последним нажатием клавиши и запросом.
    private static let debounceNanoseconds: UInt64 = 300_000_000
    private static let pageSize = 20

    @Published var query: String = ""
    @Published var filter: Filter = .all
    @Published private(set) var state: State = .idle
    @Published private(set) var history: [String] = []
    /// Подсказки во время ввода: совпадения из истории и недавно сыгранного.
    @Published private(set) var suggestions: [String] = []
    /// Догрузка следующей страницы треков («Показать ещё»).
    @Published private(set) var isLoadingMore = false
    /// Сервер вернул полную страницу — возможно, есть следующая.
    @Published private(set) var hasMoreTracks = false

    let userID: Int

    private let provider: any SearchProviding
    private let historyStore: SearchHistoryStore
    private let logger = Logger(subsystem: "com.example.ymusic", category: "Search")

    private var pendingTask: Task<Void, Never>?
    private var page = 0

    init(
        userID: Int,
        provider: any SearchProviding = YandexSearchProvider.shared,
        historyStore: SearchHistoryStore = .shared
    ) {
        self.userID = userID
        self.provider = provider
        self.historyStore = historyStore
    }

    var results: SearchResult? {
        if case .loaded(let result) = state { return result }
        return nil
    }

    var isShowingHistory: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Ввод

    func loadHistory() {
        history = historyStore.load(userID: userID)
    }

    /// Вызывается на каждое изменение `query` из `.onChange`.
    func queryChanged() {
        updateSuggestions()
        scheduleSearch()
    }

    /// Смена быстрого фильтра: если запрос уже есть — ищем заново, иначе
    /// достаточно обновить подсветку чипа.
    func selectFilter(_ newFilter: Filter) {
        guard filter != newFilter else { return }
        filter = newFilter
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        cancelPending()
        startSearch(trimmed)
    }

    /// Локальные подсказки: история + недавно сыгранные треки и артисты,
    /// начинающиеся с введённого текста. Сети здесь нет — дешёво на каждый
    /// символ. При пустом запросе подсказки не показываем.
    private func updateSuggestions() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            suggestions = []
            return
        }

        var seen = Set<String>()
        var result: [String] = []

        func append(_ candidate: String) {
            let value = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.count >= 2 else { return }
            guard value.range(of: trimmed, options: .caseInsensitive) != nil else { return }
            guard value.caseInsensitiveCompare(trimmed) != .orderedSame else { return }
            guard seen.insert(value.lowercased()).inserted else { return }
            result.append(value)
        }

        history.forEach(append)
        for entry in PlayHistoryStore.shared.entries {
            append(entry.track.title)
            append(entry.track.artist)
        }

        suggestions = Array(result.prefix(6))
    }

    /// Тап по подсказке: подставляем текст и ищем сразу.
    func applySuggestion(_ text: String) {
        submit(text)
    }

    /// Тап по истории или возврат на клавиатуре. Обычно запрос запускает
    /// `.onChange` на `query`; если текст не изменился (повторный тап по той
    /// же строке истории), `.onChange` не сработает — тогда ищем вручную.
    func submit(_ text: String) {
        if query == text {
            queryChanged()
        } else {
            query = text
        }
    }

    func clearQuery() {
        cancelPending()
        query = ""
        state = .idle
        suggestions = []
        page = 0
        hasMoreTracks = false
        isLoadingMore = false
    }

    func clearHistory() {
        historyStore.clear(userID: userID)
        history = []
    }

    func retry() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        cancelPending()
        startSearch(trimmed)
    }

    /// Уход с экрана: снимаем и дебаунс, и сетевой запрос.
    func cancel() {
        cancelPending()
    }

    // MARK: - Внутреннее

    private func scheduleSearch() {
        cancelPending()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            state = .idle
            return
        }

        pendingTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.debounceNanoseconds)
            guard let self, !Task.isCancelled else { return }
            self.startSearch(trimmed)
        }
    }

    /// Запускает запрос как новую задачу и ждёт её. `pendingTask` уже снят
    /// вызывающим, поэтому хранить отдельно сетевую задачу не нужно:
    /// отмена `pendingTask` отменяет и вложенный `await`.
    private func startSearch(_ text: String) {
        state = .loading
        page = 0
        hasMoreTracks = false
        isLoadingMore = false

        pendingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.provider.search(
                    query: text,
                    type: self.filter.apiType,
                    page: 0,
                    limit: Self.pageSize
                )
                guard !Task.isCancelled else { return }
                self.state = .loaded(result)
                self.hasMoreTracks = result.tracks.count >= Self.pageSize
                self.history = self.historyStore.record(text, userID: self.userID)
            } catch is CancellationError {
                return
            } catch let error as APIError {
                guard !Task.isCancelled, !error.isCancellation else { return }
                self.logger.error("Поиск: \(error.localizedDescription, privacy: .public)")
                self.state = .failed(error)
            } catch {
                guard !Task.isCancelled else { return }
                self.logger.error("Поиск: \(error.localizedDescription, privacy: .public)")
                self.state = .failed(.unknown(error.localizedDescription))
            }
        }
    }

    // MARK: - Пагинация

    /// Следующая страница треков. Артисты/альбомы/плейлисты остаются из
    /// первой страницы: «Показать ещё» относится только к длинному списку
    /// треков, остальные секции — витрины.
    func loadMore() {
        guard hasMoreTracks, !isLoadingMore else { return }

        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let current = results else { return }

        let nextPage = page + 1
        isLoadingMore = true

        pendingTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isLoadingMore = false
            }

            do {
                let next = try await self.provider.search(
                    query: text,
                    type: self.filter.apiType,
                    page: nextPage,
                    limit: Self.pageSize
                )
                guard !Task.isCancelled else { return }

                self.page = nextPage
                self.hasMoreTracks = next.tracks.count >= Self.pageSize
                self.state = .loaded(Self.merge(current, next))
            } catch is CancellationError {
                return
            } catch let error as APIError {
                guard !Task.isCancelled, !error.isCancellation else { return }
                // Ошибку догрузки не показываем карточкой: уже найденное
                // должно остаться на экране, кнопка даёт повторить.
                self.logger.error("Поиск, страница: \(error.localizedDescription, privacy: .public)")
            } catch {
                guard !Task.isCancelled else { return }
                self.logger.error("Поиск, страница: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func merge(_ old: SearchResult, _ new: SearchResult) -> SearchResult {
        var tracks = old.tracks
        var seenTracks = Set(tracks.map(\.id))
        for track in new.tracks where seenTracks.insert(track.id).inserted {
            tracks.append(track)
        }

        var artists = old.artists
        var seenArtists = Set(artists.map(\.id))
        for artist in new.artists where seenArtists.insert(artist.id).inserted {
            artists.append(artist)
        }

        var albums = old.albums
        var seenAlbums = Set(albums.map(\.id))
        for album in new.albums where seenAlbums.insert(album.id).inserted {
            albums.append(album)
        }

        var playlists = old.playlists
        var seenPlaylists = Set(playlists.map(\.id))
        for playlist in new.playlists where seenPlaylists.insert(playlist.id).inserted {
            playlists.append(playlist)
        }

        return SearchResult(
            tracks: tracks,
            artists: artists,
            albums: albums,
            playlists: playlists
        )
    }

    private func cancelPending() {
        pendingTask?.cancel()
        pendingTask = nil
    }

    deinit {
        pendingTask?.cancel()
    }
}
