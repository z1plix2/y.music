import SwiftUI
import UIKit

/// Музыкальная открытка 9:16 для шаринга: градиент из палитры обложки,
/// сама обложка, подписи и QR на `ymusic://track/{id}`.
///
/// Собирается как обычный SwiftUI-view и рендерится в `UIImage` через
/// `UIHostingController` + `UIGraphicsImageRenderer` (iOS 15): `ImageRenderer`
/// появился только в iOS 16. Вёрстка идёт в точках 360×640, а рендер — с
/// масштабом 3, поэтому на выходе ровно 1080×1920.
struct ShareCardView: View {
    let track: Track
    let palette: ColorPalette
    let artwork: UIImage?
    let qrImage: UIImage?
    /// Секунда, с которой начнётся воспроизведение по ссылке из QR.
    var startTime: Double?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [palette.primary.color, palette.secondary.color],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // Затемнение по краям: без него светлая обложка сливается с фоном.
            RadialGradient(
                colors: [.clear, .black.opacity(0.45)],
                center: .center,
                startRadius: 120,
                endRadius: 380
            )

            VStack(spacing: 18) {
                Spacer(minLength: 24)

                cover

                VStack(spacing: 6) {
                    Text(track.title)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)

                    Text(track.artistLine)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
                .padding(.horizontal, 24)

                Spacer(minLength: 12)

                footer
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 22)
        }
        .frame(width: Self.width, height: Self.height)
    }

    static let width: CGFloat = 360
    static let height: CGFloat = 640

    private var cover: some View {
        Group {
            if let artwork {
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.white.opacity(0.12)
                    Image(systemName: "music.note")
                        .font(.system(size: 44, weight: .medium))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
        }
        .frame(width: 236, height: 236)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 20, x: 0, y: 12)
    }

    private var footerHint: String {
        guard let startTime, startTime > 1 else {
            return "Наведи камеру — откроется трек"
        }
        let total = Int(startTime.rounded())
        let text = String(format: "%d:%02d", total / 60, total % 60)
        return "Наведи камеру — трек с \(text)"
    }

    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .font(.system(size: 13, weight: .semibold))
                    Text("слушаю в YMusic")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.85))

                Text(footerHint)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Spacer(minLength: 0)

            if let qrImage {
                Image(uiImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 56, height: 56)
                    .padding(5)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Рендер и QR

/// Сборка картинки для `UIActivityViewController`.
///
/// Палитра и обложка берутся из уже прогретых кэшей (`ColorExtractor`,
/// `ImageLoader`), поэтому открытка не ждёт сеть повторно. Если обложки нет —
/// рендерим с фирменным градиентом, а не падаем.
@MainActor
enum ShareCardRenderer {
    static func image(for track: Track, startAt: Double? = nil) async -> UIImage {
        let artwork: UIImage?
        if let artworkURL = track.artworkURL {
            artwork = await ImageLoader.shared.image(for: artworkURL)
        } else {
            artwork = nil
        }

        let palette: ColorPalette
        if let artworkURL = track.artworkURL,
           let extracted = await ColorExtractor.shared.palette(forKey: artworkURL.absoluteString, from: artworkURL) {
            palette = extracted
        } else {
            palette = .brand
        }

        let qr = QRCode.image(from: Self.link(for: track, startAt: startAt), size: 256)

        return render(
            ShareCardView(
                track: track,
                palette: palette,
                artwork: artwork,
                qrImage: qr,
                startTime: startAt
            )
        )
    }

    /// Ссылка для QR: с `?t=`, если известна секунда.
    static func link(for track: Track, startAt: Double?) -> String {
        guard let startAt, startAt > 1 else {
            return "ymusic://track/\(track.id)"
        }
        let seconds = Int(startAt.rounded())
        return "ymusic://track/\(track.id)?t=\(seconds)"
    }

    private static func render<V: View>(_ view: V) -> UIImage {
        let size = CGSize(width: ShareCardView.width, height: ShareCardView.height)
        let controller = UIHostingController(rootView: view)
        controller.view.bounds = CGRect(origin: .zero, size: size)
        controller.view.backgroundColor = .black
        controller.view.layoutIfNeeded()

        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = true

        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
    }
}

/// QR без сторонних библиотек: CoreImage умеет это из коробки.
enum QRCode {
    private static let context = CIContext()

    static func image(from string: String, size: CGFloat) -> UIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let output = filter.outputImage else { return nil }
        let scale = size / max(output.extent.width, 1)
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

// MARK: - Системный лист «Поделиться»

/// Обёртка над `UIActivityViewController`: `ShareLink` есть только с iOS 16,
/// а SwiftUI-представления система не принимает — нужен именно `UIImage`.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// `[Any]` для `.sheet(item:)`: картинка или URL видео.
struct SharePayload: Identifiable {
    let id = UUID()
    let items: [Any]
}