import Combine
import Foundation
import OSLog

/// «Моя волна» на главном. Загружается один раз и по кнопке «Повторить»;
/// пустой список провайдер отдаёт как ошибку, поэтому состояния `loaded([])`
/// здесь не бывает — экран не покажет «нет рекомендаций» вместо треков.
@MainActor
final class WaveViewModel: ObservableObject {
    enum State {
        case idle
        case loading
        case loaded([Track])
        case failed(APIError)
    }

    /// Сколько треков показываем в карточке (остальную волну не тянем).
    private static let previewCount = 5

    @Published private(set) var state: State = .idle

    private let provider: any RotorProviding
    private let logger = Logger(subsystem: "com.example.ymusic", category: "Wave")

    init(provider: any RotorProviding = YandexRotorProvider.shared) {
        self.provider = provider
    }

    var tracks: [Track] {
        if case .loaded(let tracks) = state { return tracks }
        return []
    }

    func loadIfNeeded() async {
        guard case .idle = state else { return }
        await load()
    }

    func retry() async {
        await load()
    }

    private func load() async {
        state = .loading
        do {
            let tracks = try await provider.waveTracks(limit: Self.previewCount)
            guard !Task.isCancelled else { return }
            state = .loaded(tracks)
        } catch is CancellationError {
            return
        } catch let error as APIError {
            guard !Task.isCancelled else { return }
            logger.error("Волна: \(error.localizedDescription, privacy: .public)")
            state = .failed(error)
        } catch {
            guard !Task.isCancelled else { return }
            logger.error("Волна: \(error.localizedDescription, privacy: .public)")
            state = .failed(.unknown(error.localizedDescription))
        }
    }
}
