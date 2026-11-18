import Combine
import SwiftUI

/// Режим плеера. Хранится строкой в `@AppStorage`, чтобы пережить перезапуск.
enum PlayerMode: String {
    case standard
    case vinyl
}

/// Виниловая версия плеера: пластинка с обложкой в центре, вращение при
/// воспроизведении, тонарм и прогресс по внешнему кольцу.
///
/// Вращение — один `Timer` на 20 Гц и `@State rotation`, без опроса
/// `currentTime`: иначе перерисовка шла бы дважды в секунду по всему экрану.
/// Таймер живёт только пока view видим и приложение активно.
struct VinylPlayerView: View {
    let palette: ColorPalette
    let onClose: () -> Void
    let onExitVinyl: () -> Void

    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var likes: LikeStore
    @Environment(\.contentTone) private var tone
    @Environment(\.scenePhase) private var scenePhase

    @State private var rotation: Double = 0
    @State private var needleDown = false
    @State private var artworkDrag: CGFloat = 0
    @State private var sharePayload: SharePayload?
    @State private var isPreparingShare = false
    @State private var isQueuePresented = false
    @State private var dialConnection: AnyCancellable?
    @State private var isVisible = false

    /// 20 Гц вместо 30: вращение диска плавное, CPU-пробуждений меньше.
    private let dial = Timer.publish(every: 1.0 / 20.0, on: .main, in: .common).autoconnect()

    private var track: Track? { player.currentTrack }

    private var progress: Double {
        let total = max(player.duration, track?.duration ?? 0)
        guard total > 0 else { return 0 }
        return min(max(player.currentTime / total, 0), 1)
    }

    var body: some View {
        GeometryReader { proxy in
            let discSize = min(max(proxy.size.width - 88, 200), 330)

            VStack(spacing: 0) {
                header

                Spacer(minLength: 12)

                disc(discSize: discSize)

                Spacer(minLength: 16)

                titles

                Spacer(minLength: 12)

                actions
                    .padding(.bottom, max(proxy.safeAreaInsets.bottom, 18))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            isVisible = true
            if player.isPlaying {
                needleDown = true
                Haptics.light()
            }
            updateDial()
        }
        .onDisappear {
            isVisible = false
            dialConnection?.cancel()
            dialConnection = nil
        }
        .onChange(of: player.isPlaying) { playing in
            withAnimation(.spring(response: 0.8, dampingFraction: 0.6)) {
                needleDown = playing
            }
            updateDial()
        }
        .onChange(of: scenePhase) { _ in
            updateDial()
        }
        .sheet(item: $sharePayload) { item in
            ActivityView(items: item.items)
        }
        .sheet(isPresented: $isQueuePresented) {
            QueueView()
                .environmentObject(player)
        }
    }

    // MARK: - Вращение

    /// Таймер живёт только когда view видим, приложение активно и трек играет.
    /// В фоне и под открытым sheet он отключён совсем, а не «тикает вхолостую».
    private func updateDial() {
        let shouldRun = isVisible && scenePhase == .active && player.isPlaying

        guard shouldRun else {
            dialConnection?.cancel()
            dialConnection = nil
            return
        }

        guard dialConnection == nil else { return }
        dialConnection = dial.sink { _ in
            rotation += 4.5
            if rotation >= 360 { rotation -= 360 }
        }
    }

    // MARK: - Шапка

    private var header: some View {
        HStack(spacing: 10) {
            GlassIconButton("chevron.down.circle", label: "Обычный плеер") {
                Haptics.selection()
                onExitVinyl()
            }

            Spacer(minLength: 4)

            Text("ВИНИЛ")
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.6)
                .foregroundStyle(tone.tertiary)

            Spacer(minLength: 4)

            GlassIconButton("xmark", label: "Закрыть плеер") {
                onClose()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    // MARK: - Пластинка

    private func disc(discSize: CGFloat) -> some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(red: 0.12, green: 0.12, blue: 0.14),
                                Color(red: 0.03, green: 0.03, blue: 0.04)
                            ],
                            center: .center,
                            startRadius: 10,
                            endRadius: discSize * 0.55
                        )
                    )

                ForEach(0..<16, id: \.self) { index in
                    Circle()
                        .strokeBorder(Color.white.opacity(index % 2 == 0 ? 0.045 : 0.02), lineWidth: 0.8)
                        .padding(CGFloat(index + 1) * discSize * 0.017)
                }

                Circle()
                    .fill(
                        AngularGradient(
                            colors: [
                                .clear,
                                Color.white.opacity(0.07),
                                .clear,
                                Color.white.opacity(0.035),
                                .clear
                            ],
                            center: .center
                        )
                    )
                    .blendMode(.screen)

                cover(discSize: discSize)

                Circle()
                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
            }
            .frame(width: discSize, height: discSize)
            .rotationEffect(.degrees(rotation))
            .shadow(color: .black.opacity(0.55), radius: 32, x: 8, y: 22)
            .contentShape(Circle())
            .onTapGesture {
                Haptics.light()
                player.togglePlayPause()
            }
            .simultaneousGesture(discSwipe)
            .background { glow(discSize: discSize) }
            .overlay {
                progressRing(discSize: discSize)
            }

            tonearm(discSize: discSize)
                .offset(x: discSize * 0.07, y: -discSize * 0.02)
        }
        .frame(width: discSize, height: discSize)
        .offset(x: artworkDrag * 0.16)
        .padding(.horizontal, 20)
    }

    private func cover(discSize: CGFloat) -> some View {
        CachedAsyncImage(url: track?.artworkURL) {
            ZStack {
                Color.white.opacity(0.08)
                Image(systemName: "music.note")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.white.opacity(0.25))
            }
        }
        .frame(width: discSize * 0.52, height: discSize * 0.52)
        .clipShape(Circle())
        .overlay {
            Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: 6)
    }

    private func progressRing(discSize: CGFloat) -> some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.08), lineWidth: 3)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    palette.primary.color,
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.5), value: player.currentTime)
        }
        .padding(-9)
        .allowsHitTesting(false)
    }

    private func glow(discSize: CGFloat) -> some View {
        Circle()
            .fill(palette.primary.color)
            .blur(radius: 46)
            .opacity(player.isPlaying ? 0.20 : 0.10)
            .padding(6)
            .drawingGroup()
            .allowsHitTesting(false)
    }

    private func tonearm(discSize: CGFloat) -> some View {
        let armLength = discSize * 0.46

        return VStack(spacing: 0) {
            ZStack {
                Circle().fill(Color.white.opacity(0.16))
                Circle().fill(Color.white.opacity(0.42)).frame(width: 7, height: 7)
            }
            .frame(width: 24, height: 24)

            Capsule()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.6),
                            Color.white.opacity(0.16)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 4, height: armLength)
                .overlay(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.white.opacity(0.72))
                        .frame(width: 11, height: 20)
                        .offset(y: 10)
                }
        }
        .rotationEffect(.degrees(needleDown ? 0 : -17), anchor: .top)
        .shadow(color: .black.opacity(0.35), radius: 8, x: 2, y: 6)
        .allowsHitTesting(false)
    }

    // MARK: - Подписи

    private var titles: some View {
        VStack(spacing: 6) {
            Text(track?.title ?? "Ничего не играет")
                .font(.system(size: 21, weight: .bold, design: .rounded))
                .foregroundStyle(tone.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 24)

            Text(track?.artistLine ?? "—")
                .font(.subheadline)
                .foregroundStyle(tone.secondary)
                .lineLimit(1)
                .padding(.horizontal, 24)

            Text("\(Self.timeText(player.currentTime)) · \(Self.timeText(max(player.duration, track?.duration ?? 0)))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(tone.tertiary)
                .padding(.top, 2)
        }
    }

    // MARK: - Действия

    private var actions: some View {
        HStack(spacing: 26) {
            if let track {
                LikeButton(
                    isLiked: likes.isLiked(track.id),
                    isPending: likes.isPending(track.id),
                    size: 40
                ) {
                    Task { await likes.toggle(track) }
                }
                .accessibilityLabel(
                    likes.isLiked(track.id) ? "Убрать из «Мне нравится»" : "Добавить в «Мне нравится»"
                )
            }

            glassAction("list.bullet", label: "Очередь") {
                isQueuePresented = true
            }

            glassAction("square.and.arrow.up", label: "Поделиться") {
                prepareShare()
            }
            .disabled(isPreparingShare)
        }
        .frame(maxWidth: .infinity)
    }

    private func glassAction(
        _ symbol: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.light()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tone.primary)
                .frame(width: 44, height: 44)
                .background { Circle().fill(Color.white.opacity(0.07)) }
                .overlay {
                    Circle().strokeBorder(Color.white.opacity(0.13), lineWidth: 1)
                }
        }
        .buttonStyle(PressableStyle(scale: 0.9))
        .accessibilityLabel(label)
    }

    // MARK: - Жесты

    /// Свайп по пластинке: влево — следующий, вправо — предыдущий.
    /// Горизонталь проверяется, чтобы не мешать вертикальному скроллу.
    private var discSwipe: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                artworkDrag = value.translation.width
            }
            .onEnded { value in
                let width = value.translation.width
                if width <= -80 {
                    Haptics.light()
                    player.next()
                } else if width >= 80 {
                    Haptics.light()
                    player.previous()
                }

                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                    artworkDrag = 0
                }
            }
    }

    // MARK: - Открытка

    private func prepareShare() {
        guard let track, !isPreparingShare else { return }
        isPreparingShare = true

        Task { @MainActor in
            let image = await ShareCardRenderer.image(for: track)
            isPreparingShare = false
            sharePayload = SharePayload(items: [image])
        }
    }

    private static func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}