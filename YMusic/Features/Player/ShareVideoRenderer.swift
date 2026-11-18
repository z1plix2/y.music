import AVFoundation
import CoreImage
import OSLog
import SwiftUI
import UIKit

/// Сцена видео-открытки. Рисуется по кадру: время приходит снаружи,
/// поэтому анимация детерминирована и не зависит от частоты кадров.
struct ShareVideoScene: View {
    let track: Track
    let palette: ColorPalette
    let artwork: UIImage?
    let qr: UIImage?
    let time: Double

    static let size = CGSize(width: 1080, height: 1920)

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                Spacer(minLength: 150)

                cover

                WaveVisualizer(isPlaying: true, height: 150, palette: palette, fixedTime: time)
                    .padding(.horizontal, 120)
                    .padding(.top, 54)

                Spacer(minLength: 60)

                VStack(spacing: 18) {
                    Text(track.title)
                        .font(.system(size: 64, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)

                    Text(track.artistLine)
                        .font(.system(size: 36, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                }
                .padding(.horizontal, 90)

                Spacer(minLength: 70)

                footer
                    .padding(.horizontal, 90)
                    .padding(.bottom, 120)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipped()
    }

    private var background: some View {
        ZStack {
            LinearGradient(
                colors: [palette.primary.color, palette.secondary.color],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // Медленно плавающие пятна: сцена не выглядит статичной,
            // хотя верстка одна и та же.
            RadialGradient(
                colors: [palette.secondary.color.opacity(0.85), .clear],
                center: UnitPoint(
                    x: 0.5 + 0.18 * sin(time * 0.5),
                    y: 0.25 + 0.12 * cos(time * 0.4)
                ),
                startRadius: 10,
                endRadius: 900
            )

            RadialGradient(
                colors: [palette.primary.color.opacity(0.75), .clear],
                center: UnitPoint(
                    x: 0.5 - 0.2 * cos(time * 0.35),
                    y: 0.8 + 0.1 * sin(time * 0.45)
                ),
                startRadius: 10,
                endRadius: 1100
            )

            LinearGradient(
                colors: [.black.opacity(0.15), .black.opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

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
                        .font(.system(size: 120, weight: .medium))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
        }
        .frame(width: 600, height: 600)
        .clipShape(RoundedRectangle(cornerRadius: 54, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 54, style: .continuous)
                .strokeBorder(.white.opacity(0.24), lineWidth: 2)
        }
        .shadow(color: .black.opacity(0.45), radius: 60, x: 0, y: 36)
        .scaleEffect(1 + 0.012 * sin(time * 0.8))
    }

    private var footer: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform")
                        .font(.system(size: 30, weight: .semibold))

                    Text("слушаю в YMusic")
                        .font(.system(size: 34, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.9))

                Text("Наведи камеру — откроется трек")
                    .font(.system(size: 24))
                    .foregroundStyle(.white.opacity(0.55))
            }

            Spacer(minLength: 0)

            if let qr {
                Image(uiImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 150, height: 150)
                    .padding(12)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
    }
}

enum ShareVideoError: LocalizedError {
    case notPlaying
    case noAudioTrack
    case writerSetup
    case writerFailed
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .notPlaying:
            return "Трек ещё не загрузился для экспорта"
        case .noAudioTrack:
            return "В треке нет звуковой дорожки"
        case .writerSetup:
            return "Не удалось подготовить видео"
        case .writerFailed:
            return "Не удалось записать видео"
        case .exportFailed:
            return "Не удалось вырезать фрагмент трека"
        }
    }
}

/// Сборка вертикального MP4 1080×1920, 30 FPS, 10 секунд.
///
/// Видео кодируется `AVAssetWriter` (H.264 + AAC). Кадр — это SwiftUI-вьюха,
/// отрисованная через `UIHostingController` и `UIGraphicsImageRenderer`:
/// UIKit требует главного потока, поэтому кадры идут по одному с `Task.yield()`
/// между ними, а приём аудио и запись на диск идут параллельно.
///
/// Звук — 10 секунд с текущей позиции, с fade-in 1 с и fade-out 2 с.
/// Сначала фрагмент вырезается в M4A через `AVAssetExportSession`
/// (он нормализует таймлайн к нулю), затем читается PCM и пишется в MP4.
@MainActor
final class ShareVideoRenderer: ObservableObject {
    @Published private(set) var isRendering = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var failure: String?

    private let logger = Logger(subsystem: "com.example.ymusic", category: "ShareVideo")

    private static let width = 1080
    private static let height = 1920
    private static let fps: Int32 = 30
    private static let duration: Double = 10

    /// Возвращает готовый MP4 во временной папке.
    func render(track: Track, asset: AVAsset?, startTime: Double) async throws -> URL {
        guard !isRendering else { throw ShareVideoError.writerSetup }
        guard let asset else { throw ShareVideoError.notPlaying }

        isRendering = true
        progress = 0
        failure = nil
        defer { isRendering = false }

        do {
            let artwork: UIImage?
            if let artworkURL = track.artworkURL {
                artwork = await ImageLoader.shared.image(for: artworkURL)
            } else {
                artwork = nil
            }

            let palette: ColorPalette
            if let url = track.artworkURL,
               let extracted = await ColorExtractor.shared.palette(forKey: url.absoluteString, from: url) {
                palette = extracted
            } else {
                palette = .brand
            }

            let qr = QRCode.image(from: "ymusic://track/\(track.id)", size: 512)
            let audioURL = try await exportAudio(from: asset, start: startTime)
            defer { try? FileManager.default.removeItem(at: audioURL) }

            let url = try await writeVideo(
                track: track,
                palette: palette,
                artwork: artwork,
                qr: qr,
                audioURL: audioURL
            )

            progress = 1
            return url
        } catch {
            logger.error("Видео: \(error.localizedDescription, privacy: .public)")
            failure = error.localizedDescription
            throw error
        }
    }

    // MARK: - Аудио

    private func exportAudio(from asset: AVAsset, start: Double) async throws -> URL {
        let audioTracks = asset.tracks(withMediaType: .audio)
        guard let sourceTrack = audioTracks.first else { throw ShareVideoError.noAudioTrack }

        let assetDuration = CMTimeGetSeconds(asset.duration)
        guard assetDuration.isFinite, assetDuration > 0 else { throw ShareVideoError.exportFailed }

        let safeStart = min(max(start, 0), max(assetDuration - 1, 0))
        let available = max(assetDuration - safeStart, 0.5)
        let clipDuration = min(Self.duration, available)

        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ShareVideoError.writerSetup
        }

        let range = CMTimeRange(
            start: CMTime(seconds: safeStart, preferredTimescale: 600),
            duration: CMTime(seconds: clipDuration, preferredTimescale: 600)
        )
        try track.insertTimeRange(range, of: sourceTrack, at: .zero)

        let mix = AVMutableAudioMix()
        let params = AVMutableAudioMixInputParameters(track: track)
        params.setVolumeRamp(
            fromStartVolume: 0,
            toEndVolume: 1,
            timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600))
        )
        let fadeOutStart = max(clipDuration - 2, 1)
        params.setVolumeRamp(
            fromStartVolume: 1,
            toEndVolume: 0,
            timeRange: CMTimeRange(
                start: CMTime(seconds: fadeOutStart, preferredTimescale: 600),
                duration: CMTime(seconds: clipDuration - fadeOutStart, preferredTimescale: 600)
            )
        )
        mix.inputParameters = [params]

        guard let session = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw ShareVideoError.exportFailed
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("YMusicAudio-\(UUID().uuidString).m4a")
        try? FileManager.default.removeItem(at: url)

        session.outputURL = url
        session.outputFileType = .m4a
        session.audioMix = mix
        session.timeRange = CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: clipDuration, preferredTimescale: 600)
        )

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously {
                continuation.resume()
            }
        }

        guard session.status == .completed else {
            throw session.error ?? ShareVideoError.exportFailed
        }
        return url
    }

    // MARK: - Видео

    private func writeVideo(
        track: Track,
        palette: ColorPalette,
        artwork: UIImage?,
        qr: UIImage?,
        audioURL: URL
    ) async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("YMusic-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: outputURL)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw ShareVideoError.writerSetup
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Self.width,
            AVVideoHeightKey: Self.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 4_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: 30
            ]
        ]

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Self.width,
                kCVPixelBufferHeightKey as String: Self.height
            ]
        )

        guard writer.canAdd(videoInput) else { throw ShareVideoError.writerSetup }
        writer.add(videoInput)

        // Аудио: читаем PCM из вырезанного M4A и отдаём писателю как AAC.
        let audioAsset = AVURLAsset(url: audioURL)
        guard let audioTrack = audioAsset.tracks(withMediaType: .audio).first else {
            throw ShareVideoError.noAudioTrack
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: audioAsset)
        } catch {
            throw ShareVideoError.writerSetup
        }

        let audioOutput = AVAssetReaderTrackOutput(
            track: audioTrack,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        )
        audioOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(audioOutput) else { throw ShareVideoError.writerSetup }
        reader.add(audioOutput)

        let audioInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000
            ]
        )
        audioInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(audioInput) else { throw ShareVideoError.writerSetup }
        writer.add(audioInput)

        guard writer.startWriting() else {
            throw writer.error ?? ShareVideoError.writerFailed
        }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else {
            throw reader.error ?? ShareVideoError.exportFailed
        }

        let frameCount = Int(Self.duration * Double(Self.fps))
        let size = ShareVideoScene.size

        // Один контроллер на все кадры: пересоздание 300 раз дороже,
        // чем обновление rootView.
        let controller = UIHostingController(
            rootView: ShareVideoScene(
                track: track,
                palette: palette,
                artwork: artwork,
                qr: qr,
                time: 0
            )
        )
        controller.view.bounds = CGRect(origin: .zero, size: size)
        controller.view.backgroundColor = .black
        controller.view.isOpaque = true
        controller.view.layoutIfNeeded()

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        for frame in 0..<frameCount {
            if Task.isCancelled {
                writer.cancelWriting()
                throw CancellationError()
            }

            let time = Double(frame) / Double(Self.fps)
            controller.rootView = ShareVideoScene(
                track: track,
                palette: palette,
                artwork: artwork,
                qr: qr,
                time: time
            )
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()

            let image = renderer.image { _ in
                controller.view.drawHierarchy(
                    in: controller.view.bounds,
                    afterScreenUpdates: true
                )
            }

            guard let buffer = Self.pixelBuffer(from: image) else {
                writer.cancelWriting()
                throw ShareVideoError.writerFailed
            }

            while !videoInput.isReadyForMoreMediaData {
                if writer.status == .failed {
                    throw writer.error ?? ShareVideoError.writerFailed
                }
                await Task.yield()
            }

            let presentationTime = CMTime(value: CMTimeValue(frame), timescale: Self.fps)
            guard adaptor.append(buffer, withPresentationTime: presentationTime) else {
                writer.cancelWriting()
                throw writer.error ?? ShareVideoError.writerFailed
            }

            // Аудио идёт параллельно видео по таймлайну: два буфера на кадр
            // примерно покрывают 1/30 секунды PCM.
            try pumpAudio(output: audioOutput, input: audioInput, maxBuffers: 2)

            progress = 0.35 + 0.6 * Double(frame + 1) / Double(frameCount)

            // Даём главному потоку обработать касания и обновить прогресс.
            await Task.yield()
        }

        // Остаток аудио: последние буферы могут отставать от сетки кадров.
        videoInput.markAsFinished()
        try pumpAudio(output: audioOutput, input: audioInput, maxBuffers: nil)
        audioInput.markAsFinished()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting {
                continuation.resume()
            }
        }

        guard writer.status == .completed else {
            throw writer.error ?? ShareVideoError.writerFailed
        }

        return outputURL
    }

    // MARK: - Кадр → пиксели

    /// Перекладывает готовые PCM-буферы в аудиовход писателя.
    /// `maxBuffers == nil` — до конца дорожки.
    private func pumpAudio(
        output: AVAssetReaderTrackOutput,
        input: AVAssetWriterInput,
        maxBuffers: Int?
    ) throws {
        var count = 0

        while input.isReadyForMoreMediaData {
            guard let buffer = output.copyNextSampleBuffer() else { return }
            guard input.append(buffer) else {
                throw ShareVideoError.writerFailed
            }

            count += 1
            if let maxBuffers, count >= maxBuffers {
                return
            }
        }
    }

    private static func pixelBuffer(from image: UIImage) -> CVPixelBuffer? {
        guard let cgImage = image.cgImage else { return nil }

        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer = buffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard
            let base = CVPixelBufferGetBaseAddress(pixelBuffer),
            let context = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            )
        else {
            return nil
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixelBuffer
    }
}