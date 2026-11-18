import SwiftUI
import UIKit
import WidgetKit

/// Кэш обложки для виджета.
///
/// `AsyncImage` в виджете ненадёжен (нет общего кэша и повторов), поэтому
/// качаем сами и храним PNG в контейнере App Group: следующий перезапуск
/// виджета уже не ждёт сеть. Ключ — абсолютный URL.
enum WidgetArtworkCache {
    private static let folderName = "WidgetArtwork"

    static func image(for url: URL?) -> UIImage? {
        guard let url, let file = fileURL(for: url) else { return nil }
        guard let data = try? Data(contentsOf: file) else { return nil }
        return UIImage(data: data)
    }

    /// Сеть с коротким таймаутом: провайдер ограничен по времени,
    /// обложка не стоит того, чтобы задерживать таймлайн.
    static func loadOrFetch(_ url: URL?) async -> UIImage? {
        guard let url else { return nil }

        if let cached = image(for: url) {
            return cached
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            let (data, response) = try await URLSession.shared.data(for: request)

            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return nil
            }

            guard let image = UIImage(data: data) else { return nil }
            store(data, for: url)
            return image
        } catch {
            return nil
        }
    }

    private static func store(_ data: Data, for url: URL) {
        guard let file = fileURL(for: url) else { return }
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: file, options: .atomic)
        } catch {
            // Кэш необязателен: без него просто скачаем обложку снова.
        }
    }

    private static func fileURL(for url: URL) -> URL? {
        guard let container = WidgetSharedStore.containerURL else { return nil }
        let name = String(url.absoluteString.hashValue, radix: 16)
        return container
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent("\(name).img")
    }
}

struct YMusicEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetTrackSnapshot?
    let artwork: UIImage?
}

struct YMusicProvider: TimelineProvider {
    func placeholder(in context: Context) -> YMusicEntry {
        YMusicEntry(date: Date(), snapshot: nil, artwork: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (YMusicEntry) -> Void) {
        let snapshot = WidgetSharedStore.load()
        completion(YMusicEntry(date: Date(), snapshot: snapshot, artwork: nil))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<YMusicEntry>) -> Void) {
        let snapshot = WidgetSharedStore.load()
        let url = snapshot?.artworkURLString.flatMap(URL.init(string:))

        Task {
            let artwork = await WidgetArtworkCache.loadOrFetch(url)
            let entry = YMusicEntry(date: Date(), snapshot: snapshot, artwork: artwork)

            // Раз в 30 секунд: прогресс на виджете не должен застывать,
            // а чаще система всё равно обновлять не даст.
            let next = Date().addingTimeInterval(30)
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }
}

struct YMusicWidgetView: View {
    let entry: YMusicEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch family {
            case .systemMedium:
                medium
            default:
                small
            }
        }
        .widgetURL(URL(string: "ymusic://nowplaying"))
    }

    // MARK: - Семейства

    private var small: some View {
        ZStack(alignment: .bottomLeading) {
            artworkBackground

            LinearGradient(
                colors: [.clear, .black.opacity(0.75)],
                startPoint: .center,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 5) {
                playState

                Spacer(minLength: 0)

                if let snapshot = entry.snapshot {
                    Text(snapshot.title)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)

                    Text(snapshot.artist)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                } else {
                    Text("YMusic")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text("Нажми, чтобы открыть")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }

                progressBar
            }
            .padding(11)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var medium: some View {
        HStack(spacing: 12) {
            artworkTile
                .frame(width: 92, height: 92)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    playState
                    Spacer(minLength: 0)
                }

                Spacer(minLength: 0)

                if let snapshot = entry.snapshot {
                    Text(snapshot.title)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)

                    Text(snapshot.artist)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)

                    progressBar
                } else {
                    Text("YMusic")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text("Сейчас ничего не играет")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(2)
                }
            }
            .padding(.vertical, 4)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.11, green: 0.05, blue: 0.16),
                    Color(red: 0.05, green: 0.04, blue: 0.1)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    // MARK: - Куски

    private var artworkBackground: some View {
        Group {
            if let artwork = entry.artwork {
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(
                    colors: [
                        Color(red: 0.45, green: 0.1, blue: 0.28),
                        Color(red: 0.12, green: 0.08, blue: 0.3)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var artworkTile: some View {
        Group {
            if let artwork = entry.artwork {
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.white.opacity(0.08)
                    Image(systemName: "music.note")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
        }
    }

    private var playState: some View {
        Image(systemName: entry.snapshot?.isPlaying == true ? "pause.fill" : "play.fill")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background { Circle().fill(.white.opacity(0.18)) }
    }

    private var progressBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18))

                if let snapshot = entry.snapshot {
                    Capsule()
                        .fill(.white.opacity(0.9))
                        .frame(width: proxy.size.width * snapshot.position(at: entry.date))
                }
            }
        }
        .frame(height: 3)
    }
}

@main
struct YMusicWidget: Widget {
    private let kind = "YMusicWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: YMusicProvider()) { entry in
            YMusicWidgetView(entry: entry)
                // Фон виджета задаём сами: на iOS 15 системной подложки нет,
                // а на iOS 17+ она обязательна — этот модификатор её заменяет.
                .padding(0)
        }
        .configurationDisplayName("Сейчас играет")
        .description("Текущий трек из YMusic с прогрессом.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}