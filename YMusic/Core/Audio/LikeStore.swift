import Combine
import Foundation
import OSLog

/// Локальное состояние «Мне нравится» с оптимистичным обновлением.
///
/// UI реагирует мгновенно, сервер подтверждает позже; при ошибке состояние
/// откатывается, а кэш id в `YandexMusicCatalog` сбрасывается только при успехе.
@MainActor
final class LikeStore: ObservableObject {
    @Published private(set) var likedIDs: Set<Int> = []
    @Published private(set) var pendingIDs: Set<Int> = []

    let userID: Int
    private let provider: any LikesProviding
    private let catalog: YandexMusicCatalog
    private let logger = Logger(subsystem: "com.example.ymusic", category: "Likes")

    init(
        userID: Int,
        provider: any LikesProviding = YandexLikesProvider.shared,
        catalog: YandexMusicCatalog = .shared
    ) {
        self.userID = userID
        self.provider = provider
        self.catalog = catalog
    }

    func load() async {
        do {
            let ids = try await provider.likedTrackIDs(userID: userID)
            likedIDs = Set(ids)
        } catch {
            // Без стартового списка сердечки просто пустые: это не повод
            // показывать ошибку вместо каталога.
            logger.error("Стартовые лайки: \(error.localizedDescription, privacy: .public)")
        }
    }

    func isLiked(_ trackID: Int) -> Bool {
        likedIDs.contains(trackID)
    }

    func isPending(_ trackID: Int) -> Bool {
        pendingIDs.contains(trackID)
    }

    /// Возвращает состояние после операции: `true` — теперь в лайках.
    @discardableResult
    func toggle(_ track: Track) async -> Bool {
        guard !pendingIDs.contains(track.id) else {
            return isLiked(track.id)
        }

        let wasLiked = likedIDs.contains(track.id)
        setLiked(!wasLiked, trackID: track.id)
        pendingIDs.insert(track.id)

        do {
            if wasLiked {
                try await provider.removeLike(track: track, userID: userID)
            } else {
                try await provider.addLike(track: track, userID: userID)
            }
            pendingIDs.remove(track.id)
            await catalog.invalidateLikesCache(userID: userID)
            return !wasLiked
        } catch {
            setLiked(wasLiked, trackID: track.id)
            pendingIDs.remove(track.id)
            logger.error("Лайк: \(error.localizedDescription, privacy: .public)")
            return wasLiked
        }
    }

    private func setLiked(_ liked: Bool, trackID: Int) {
        if liked {
            likedIDs.insert(trackID)
        } else {
            likedIDs.remove(trackID)
        }
    }
}
