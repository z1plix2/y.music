import SwiftUI

/// Визуализатор «частицы» под обложкой.
///
/// Настоящий FFT недоступен: `AVPlayer` не отдаёт аудиобуфер без
/// `AVAudioEngine`/`MTAudioProcessingTap`, а переделывать звуковой тракт
/// ради картинки — не та цена. Поэтому частицы живут по своей формуле:
/// поднимаются снизу, дрейфуют вбок и затухают. На паузе `TimelineView`
/// останавливает кадры совсем — картинка замирает и не жжёт CPU.
///
/// Время кадра можно передать снаружи (`fixedTime`) — так видео-открытка
/// рендерит кадры вразнобой, без живой анимации.
struct WaveVisualizer: View {
    var isPlaying: Bool
    var height: CGFloat = 54
    /// Готовая палитра: нужна видео-открытке, где окружение `ContentTone`
    /// не совпадает с фоном кадра.
    var palette: ColorPalette?
    /// Обложка текущего трека: палитра подгружается сама.
    var artworkURL: URL?
    /// Меняется при смене трека — взрыв частиц из центра.
    var trackID: Int?
    /// Меняется при лайке — маленький взрыв.
    var likeToken: Int = 0
    /// Время кадра для офскрин-рендера.
    var fixedTime: Double?
    /// Реальный спектр: если загружен, рисуем 64 полосы вместо частиц.
    var spectrum: SpectrumData?
    /// Позиция трека для спектра.
    var currentTime: Double = 0

    @Environment(\.contentTone) private var tone
    @Environment(\.scenePhase) private var scenePhase
    /// На слабом железе — 12 кадров и 32 полосы.
    @ObservedObject private var device = DeviceProfile.shared
    @State private var loadedPalette: ColorPalette?
    @State private var bursts: [ParticleBurst] = []
    /// Плеер закрыт, но view ещё в памяти — кадры не нужны.
    @State private var isVisible = false
    /// Привязка «позиция трека → момент на часах» для плавности между тиками.
    @State private var anchorDate = Date()

    private static let count = 96

    /// На паузе и в фоне кадров нет совсем: `TimelineView` перестаёт тикать.
    private var isPaused: Bool {
        !isPlaying || scenePhase != .active || !isVisible || !device.allowsAnimatedVisuals
    }

    var body: some View {
        Group {
            if let fixedTime {
                Canvas { context, size in
                    drawParticles(in: context, size: size, time: fixedTime)
                }
            } else if !device.allowsAnimatedVisuals {
                // Эконом или перегрев: один статичный кадр, без таймера.
                Canvas { context, size in
                    drawStaticFrame(in: context, size: size)
                }
            } else if let spectrum, !spectrum.isEmpty {
                TimelineView(
                    .animation(minimumInterval: 1.0 / device.visualizerFrameRate, paused: isPaused)
                ) { timeline in
                    Canvas { context, size in
                        drawSpectrum(
                            spectrum,
                            in: context,
                            size: size,
                            time: spectrumTime(at: timeline.date)
                        )
                    }
                }
            } else {
                // FPS берётся из профиля: 24 на сильном железе, 12 на слабом.
                TimelineView(
                    .animation(minimumInterval: 1.0 / device.visualizerFrameRate, paused: isPaused)
                ) { timeline in
                    let time = timeline.date.timeIntervalSinceReferenceDate

                    Canvas { context, size in
                        drawParticles(in: context, size: size, time: time)
                        drawBursts(in: context, size: size, date: timeline.date)
                    }
                }
            }
        }
        .saturation(0.8)
        .frame(height: height)
        .accessibilityHidden(true)
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .onChange(of: currentTime) { _ in anchorDate = Date() }
        .task(id: artworkURL) {
            guard let artworkURL else { return }
            loadedPalette = await ColorExtractor.shared.palette(
                forKey: artworkURL.absoluteString,
                from: artworkURL
            )
        }
        .onChange(of: trackID) { _ in
            guard isPlaying else { return }
            addBurst(count: 50, spread: 1)
        }
        .onChange(of: likeToken) { _ in
            guard isPlaying else { return }
            addBurst(count: 20, spread: 0.55)
        }
    }

    // MARK: - Палитра

    private var activePalette: ColorPalette {
        palette ?? loadedPalette ?? .brand
    }

    private var primaryColor: Color {
        palette == nil && loadedPalette == nil ? tone.primary : activePalette.primary.color
    }

    private var secondaryColor: Color {
        palette == nil && loadedPalette == nil ? tone.secondary : activePalette.secondary.color
    }

    // MARK: - Спектр

    private func spectrumTime(at date: Date) -> Double {
        let elapsed = date.timeIntervalSince(anchorDate)
        return currentTime + min(max(elapsed, 0), 0.4)
    }

    private func drawSpectrum(
        _ spectrum: SpectrumData,
        in context: GraphicsContext,
        size: CGSize,
        time: Double
    ) {
        guard size.width > 0, size.height > 0 else { return }

        let values = Self.downsample(
            spectrum.values(at: max(time, 0)),
            to: device.spectrumBarCount
        )
        guard !values.isEmpty else { return }

        let count = values.count
        let slot = size.width / CGFloat(count)
        let gap = max(slot * 0.24, 0.5)
        let barWidth = max(slot - gap, 0.8)

        let shading = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [primaryColor, secondaryColor]),
            startPoint: CGPoint(x: 0, y: size.height),
            endPoint: CGPoint(x: size.width, y: size.height)
        )

        for index in 0..<count {
            let level = CGFloat(values[index])
            let height = max(2, level * (size.height - 4))
            let rect = CGRect(
                x: CGFloat(index) * slot + gap / 2,
                y: size.height - height,
                width: barWidth,
                height: height
            )
            context.fill(
                Path(roundedRect: rect, cornerRadius: barWidth / 2),
                with: shading
            )
        }
    }

    // MARK: - Частицы

    /// Статичный кадр для эконом-режима: спектр на текущей позиции или
    /// застывшие частицы.
    private func drawStaticFrame(in context: GraphicsContext, size: CGSize) {
        if let spectrum, !spectrum.isEmpty {
            drawSpectrum(spectrum, in: context, size: size, time: max(currentTime, 0))
        } else {
            drawParticles(in: context, size: size, time: 0)
        }
    }

    /// Схлопывает 64 полосы в 32 по пику: на слабом железе вдвое меньше фигур.
    private static func downsample(_ values: [Float], to target: Int) -> [Float] {
        guard target > 0, values.count > target else { return values }
        let groupSize = max(values.count / target, 1)
        var result = [Float](repeating: 0, count: target)

        for index in 0..<target {
            let lower = index * groupSize
            let upper = min(lower + groupSize, values.count)
            var peak: Float = 0
            if lower < upper {
                for bin in lower..<upper {
                    peak = max(peak, values[bin])
                }
            }
            result[index] = peak
        }
        return result
    }

    private func drawParticles(in context: GraphicsContext, size: CGSize, time: Double) {
        guard size.width > 0, size.height > 0 else { return }

        let baseAlpha = isPlaying ? 0.7 : 0.28

        for index in 0..<Self.count {
            let seed = Self.fract(Double(index) * 0.6180339887)
            let cycle = 4.5 + 4.5 * Self.fract(seed * 5.1)
            let progress = Self.fract(time / cycle + seed)
            let drift = sin(time * 0.9 + seed * 6.28) * 12

            let x = size.width * (0.04 + 0.92 * Self.fract(seed * 2.3)) + drift
            let y = size.height * (1 - progress)
            let radius = 1.5 + 3.5 * Self.fract(seed * 7.1)

            // Затухание к верху: частица рождается и растворяется.
            let alpha = baseAlpha * sin(progress * .pi)
            guard alpha > 0.01 else { continue }

            let color = index.isMultiple(of: 3) ? secondaryColor : primaryColor
            let rect = CGRect(
                x: x - radius,
                y: y - radius,
                width: radius * 2,
                height: radius * 2
            )
            context.fill(Path(ellipseIn: rect), with: .color(color.opacity(alpha)))
        }
    }

    // MARK: - Взрывы

    private func addBurst(count: Int, spread: Double) {
        let burst = ParticleBurst(
            start: Date(),
            spread: spread,
            particles: (0..<count).map { index in
                let seed = Self.fract(Double(index) * 0.7548776662)
                return BurstParticle(
                    angle: Double(index) / Double(max(count, 1)) * .pi * 2 + seed,
                    distance: 0.35 + 0.65 * seed,
                    size: 1.5 + 3 * Self.fract(seed * 3.7),
                    alternate: index.isMultiple(of: 2)
                )
            }
        )

        bursts.append(burst)
        if bursts.count > 3 {
            bursts.removeFirst(bursts.count - 3)
        }
    }

    private func drawBursts(in context: GraphicsContext, size: CGSize, date: Date) {
        guard !bursts.isEmpty else { return }

        let center = CGPoint(x: size.width / 2, y: size.height * 0.62)
        let maxDistance = max(size.width, size.height) * 0.55

        for burst in bursts {
            let elapsed = date.timeIntervalSince(burst.start)
            guard elapsed >= 0, elapsed < 1.4 else { continue }

            let progress = elapsed / 1.4
            let alpha = (1 - progress) * 0.85

            for particle in burst.particles {
                let distance = maxDistance * CGFloat(particle.distance) * CGFloat(burst.spread) * CGFloat(progress)
                let x = center.x + CGFloat(cos(particle.angle)) * distance
                let y = center.y + CGFloat(sin(particle.angle)) * distance * 0.7
                let radius = particle.size * CGFloat(1 - progress * 0.6)

                let color = particle.alternate ? secondaryColor : primaryColor
                let rect = CGRect(
                    x: x - radius,
                    y: y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
                context.fill(Path(ellipseIn: rect), with: .color(color.opacity(alpha)))
            }
        }
    }

    private static func fract(_ value: Double) -> Double {
        value - floor(value)
    }
}

private struct BurstParticle {
    let angle: Double
    let distance: Double
    let size: CGFloat
    let alternate: Bool
}

private struct ParticleBurst {
    let start: Date
    let spread: Double
    let particles: [BurstParticle]
}