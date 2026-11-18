import SwiftUI

/// Скраббер-форма волны: 200 столбиков, закрашенная часть — проигранное,
/// вертикальный playhead, бейдж с таймкодом под пальцем.
///
/// Столбики рисуются `Canvas` в два прохода (фон + прогресс), поэтому
/// 200 фигур не создают 200 View и не тормозят скролл.
struct WaveformScrubber: View {
    var fallbackDuration: Double = 0
    var accent: Color = .white

    @EnvironmentObject private var player: AudioPlayer
    @Environment(\.contentTone) private var tone

    @State private var scrubFraction: Double?
    @State private var lastHapticStep = -1

    private var duration: Double {
        max(player.duration, fallbackDuration, 1)
    }

    private var fraction: Double {
        if let scrubFraction { return scrubFraction }
        return min(max(player.currentTime / duration, 0), 1)
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)

            ZStack(alignment: .leading) {
                bars(width: width, color: accent.opacity(0.22))
                bars(width: width, color: accent)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: width * fraction)
                    }

                Rectangle()
                    .fill(accent)
                    .frame(width: 2)
                    .offset(x: max(width * fraction - 1, 0))
                    .animation(.linear(duration: 0.5), value: player.currentTime)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(scrubGesture(width: width))
        }
        .frame(height: 58)
        .overlay(alignment: .top) {
            if scrubFraction != nil {
                Text(Self.timeText(fraction * duration))
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(tone.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background { Capsule().fill(Color.black.opacity(0.55)) }
                    .overlay {
                        Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    }
                    .offset(y: -20)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: scrubFraction != nil)
        .accessibilityElement()
        .accessibilityLabel("Позиция трека")
        .accessibilityValue(Self.timeText(fraction * duration))
    }

    // MARK: - Рисование

    private func bars(width: CGFloat, color: Color) -> some View {
        Canvas { context, size in
            let values = player.waveform
            let count = values.isEmpty ? 60 : values.count
            let slot = size.width / CGFloat(max(count, 1))
            let gap = max(slot * 0.32, 0.6)
            let barWidth = max(slot - gap, 0.8)
            let midY = size.height / 2

            for index in 0..<count {
                let value = values.isEmpty ? 0.12 : CGFloat(values[index])
                let height = max(3, value * (size.height - 8))
                let rect = CGRect(
                    x: CGFloat(index) * slot + gap / 2,
                    y: midY - height / 2,
                    width: barWidth,
                    height: height
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: barWidth / 2),
                    with: .color(color)
                )
            }
        }
        .frame(width: width)
        .allowsHitTesting(false)
    }

    // MARK: - Жест

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let target = min(max(value.location.x / width, 0), 1)
                scrubFraction = target

                // Haptic каждые 5 %: 20 шагов на трек.
                let step = Int(target * 20)
                if step != lastHapticStep {
                    lastHapticStep = step
                    Haptics.selection()
                }
            }
            .onEnded { value in
                let target = min(max(value.location.x / width, 0), 1)
                player.seek(to: target * duration)
                scrubFraction = nil
                lastHapticStep = -1
                Haptics.light()
            }
    }

    private static func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}