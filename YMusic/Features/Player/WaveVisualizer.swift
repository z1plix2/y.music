import SwiftUI

/// Визуализатор под обложкой в полноэкранном плеере.
///
/// Настоящий FFT недоступен: `AVPlayer` не отдаёт аудиобуфер без
/// `AVAudioEngine`/`MTAudioProcessingTap`, а переделывать звуковой тракт
/// ради картинки — не та цена. Поэтому это честная анимация: полосы
/// качаются от суммы двух синусов, пока трек играет, и замирают на паузе.
///
/// `TimelineView` с `paused: !isPlaying` останавливает обновления полностью:
/// на паузе кадров нет, CPU не тратится. Частота — 30 FPS.
struct WaveVisualizer: View {
    var isPlaying: Bool
    var barCount: Int = 28
    var height: CGFloat = 54
    /// Время кадра для офскрин-рендера (видео-открытка): без `TimelineView`,
    /// чтобы каждый кадр рисовался ровно в свою секунду.
    var fixedTime: Double?

    @Environment(\.contentTone) private var tone

    var body: some View {
        Group {
            if let fixedTime {
                Canvas { context, size in
                    draw(in: context, size: size, time: fixedTime)
                }
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isPlaying)) { timeline in
                    let time = timeline.date.timeIntervalSinceReferenceDate

                    Canvas { context, size in
                        draw(in: context, size: size, time: time)
                    }
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    private func draw(in context: GraphicsContext, size: CGSize, time: Double) {
        let count = max(barCount, 1)
        let step = size.width / CGFloat(count)
        let barWidth = max(2, step * 0.46)

        let gradient = Gradient(colors: [
            tone.primary.opacity(0.85),
            tone.secondary.opacity(0.55)
        ])

        for index in 0..<count {
            let phase = Double(index) * 0.55
            let first = sin(time * 2.1 + phase) * 0.5 + 0.5
            let second = sin(time * 1.3 - phase * 1.7) * 0.5 + 0.5
            let level = isPlaying
                ? 0.18 + 0.82 * (first * 0.6 + second * 0.4)
                : 0.16

            let barHeight = max(4, size.height * CGFloat(level))
            let x = CGFloat(index) * step + (step - barWidth) / 2
            let y = (size.height - barHeight) / 2

            let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
            let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)

            context.fill(
                path,
                with: .linearGradient(
                    gradient,
                    startPoint: CGPoint(x: x, y: y),
                    endPoint: CGPoint(x: x, y: y + barHeight)
                )
            )
        }
    }
}