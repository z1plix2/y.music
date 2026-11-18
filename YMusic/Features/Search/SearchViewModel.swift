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

    /// Пауза между последним нажатием клавиши и запросом.
    private static let debounceNanoseconds: UInt64 = 300_000_000
    private static let pageSize = 20

    @Published var query: String = ""
    @Published private(set) var state: State = .idle
    @Published private(set) var history: [String] = []

    let userID: Int

    private let provider: any SearchProviding
    private let historyStore: SearchHistoryStore
    private let logger = Logger(subsystem: "com.example.ymusic", category: "Search")

    private var pendingTask: Task<Void, Never>?

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
        scheduleSearch()
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

        pendingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.provider.search(
                    query: text,
                    page: 0,
                    limit: Self.pageSize
                )
                guard !Task.isCancelled else { return }
                self.state = .loaded(result)
                self.history = self.historyStore.record(text, userID: self.userID)
            } catch is CancellationError {
                return
            } catch let error as APIError {
                guard !Task.isCancelled else { return }
                self.logger.error("Поиск: \(error.localizedDescription, privacy: .public)")
                self.state = .failed(error)
            } catch {
                guard !Task.isCancelled else { return }
                self.logger.error("Поиск: \(error.localizedDescription, privacy: .public)")
                self.state = .failed(.unknown(error.localizedDescription))
            }
        }
    }

    private func cancelPending() {
        pendingTask?.cancel()
        pendingTask = nil
    }

    deinit {
        pendingTask?.cancel()
    }
}
