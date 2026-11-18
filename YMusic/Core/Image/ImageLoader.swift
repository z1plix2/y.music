import ImageIO
import OSLog
import SwiftUI
import UIKit

/// Кэш обложек. `AsyncImage` в iOS 15 ничего не кэширует и перезагружает
/// картинку при каждом пересоздании ячейки, поэтому свой загрузчик.
///
/// `@MainActor`, потому что `NSCache<NSURL, UIImage>` и `UIImage` удобнее
/// держать на одном исполнителе: сеть всё равно уходит в URLSession,
/// а декодирование небольшой обложки на главном потоке незаметно.
@MainActor
final class ImageLoader {
    static let shared = ImageLoader()

    private let cache = NSCache<NSURL, UIImage>()
    private let logger = Logger(subsystem: "com.example.ymusic", category: "ImageLoader")

    init() {
        cache.countLimit = 150
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func cachedImage(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    /// Загрузка в задаче вызывающего: уход с экрана отменяет `URLSession`
    /// через отмену `Task` в `.task(id:)`, отдельный «висящий» таск не нужен.
    func image(for url: URL) async -> UIImage? {
        if let cached = cachedImage(for: url) {
            return cached
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            try Task.checkCancellation()

            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                logger.debug("Обложка пропущена: HTTP \(http.statusCode)")
                return nil
            }

            // Декодирование и даунсемплинг — вне главного потока: для обложки
            // 1000×1000 `UIImage(data:)` на main даёт заметный фриз в скролле.
            guard let image = await Self.decodeImage(from: data) else {
                logger.debug("Обложка не декодируется")
                return nil
            }

            // Греем палитру теми же байтами: DynamicBackground потом возьмёт
            // готовый цвет из кэша ColorExtractor без второго запроса.
            _ = await ColorExtractor.shared.palette(forKey: url.absoluteString, fromData: data)

            cache.setObject(image, forKey: url as NSURL, cost: data.count)
            return image
        } catch is CancellationError {
            return nil
        } catch {
            logger.debug("Обложка не загрузилась: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Декодирует сразу в нужном размере: `CGImageSourceCreateThumbnailAtIndex`
    /// не разворачивает полноразмерный битмап, поэтому дешевле и по памяти.
    nonisolated private static func decodeImage(from data: Data) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                return UIImage(data: data)
            }

            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 600,
                kCGImageSourceShouldCacheImmediately: true
            ]

            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                options as CFDictionary
            ) else {
                return UIImage(data: data)
            }

            return UIImage(cgImage: thumbnail)
        }.value
    }
}

/// Аналог `AsyncImage` с кэшем и отменой. Картинка рендерится
/// `scaledToFill`, поэтому вызывающий обязан задать размер и клип.
struct CachedAsyncImage<Placeholder: View>: View {
    private let url: URL?
    private let placeholder: () -> Placeholder

    @State private var image: UIImage?
    @State private var didFail = false

    init(url: URL?, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if didFail {
                failedView
            } else {
                placeholder()
            }
        }
        .task(id: url) { await load() }
    }

    private var failedView: some View {
        ZStack {
            Color.white.opacity(0.06)
            Image(systemName: "music.note")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white.opacity(0.25))
        }
    }

    private func load() async {
        guard let url else {
            didFail = true
            return
        }

        if let cached = ImageLoader.shared.cachedImage(for: url) {
            image = cached
            return
        }

        let loaded = await ImageLoader.shared.image(for: url)
        guard !Task.isCancelled else { return }

        if let loaded {
            image = loaded
        } else {
            didFail = true
        }
    }
}
