import SwiftUI

/// Полноэкранный плеер. Источник — тот же `AudioPlayer`, поэтому прогресс,
/// очередь и состояние совпадают с мини-плеером.
struct NowPlayingView: View {
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var likes: LikeStore
    @EnvironmentObject private var waveSession: WaveSessionController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.contentTone) private var tone

    @StateObject private var shazam = ShazamRecognizer()
    @State private var isShazamPresented = false
    @State private var sharePayload: SharePayload?
    @State private var isPreparingShare = false
    @State private var showVideoError = false
    @State private var likeBurstToken = 0
    @StateObject private var videoRenderer = ShareVideoRenderer()
    /// Плеер глушим на время распознавания: микрофон не должен слышать
    /// наш же трек. Возвращаем только если пользователь не включил другой.
    @State private var resumeAfterShazam = false
    @State private var isQueuePresented = false
    @State private var isLyricsPresented = false
    @State private var artworkDrag: CGFloat = 0
    @State private var artworkPalette: ColorPalette = .brand
    @AppStorage("playerMode") private var playerModeRaw = PlayerMode.standard.rawValue
    @AppStorage("useWaveformScrubber") private var useWaveformScrubber = true
    /// Нагрев и слабое железо: плашка и статичные эффекты.
    @ObservedObject private var device = DeviceProfile.shared

    private var mode: PlayerMode {
        PlayerMode(rawValue: playerModeRaw) ?? .standard
    }

    /// Тап по имени артиста: `MainView` закрывает плеер и открывает экран
    /// артиста. По умолчанию — ничего, чтобы старые вызовы компилировались.
    var onOpenArtist: (Int) -> Void = { _ in }

    private var track: Track? { player.currentTrack }

    var body: some View {
        DynamicBackground(
            imageURL: track?.artworkURL,
            cacheKey: track?.artworkURL?.absoluteString ?? "now-playing",
            fallback: .brand
        ) {
            modeContent
        }
        .overlay(alignment: .bottom) {
            if isShazamPresented {
                ShazamSheet(recognizer: shazam) {
                    isShazamPresented = false
                    shazam.reset()

                    if resumeAfterShazam, !player.isPlaying {
                        player.togglePlayPause()
                    }
                    resumeAfterShazam = false
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isShazamPresented)
        .animation(.easeInOut(duration: 0.35), value: playerModeRaw)
        .overlay(alignment: .top) {
            if videoRenderer.isRendering {
                HStack(spacing: 8) {
                    ProgressView()
                        .tint(.white)

                    Text("Готовим видео… \(Int(videoRenderer.progress * 100))%")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background { Capsule().fill(Color.black.opacity(0.55)) }
                .padding(.top, 56)
                .transition(.opacity)
            }
        }
        .sheet(item: $sharePayload) { item in
            ActivityView(items: item.items)
        }
        .overlay(alignment: .top) {
            heatNotice
        }
        .sheet(isPresented: $isQueuePresented) {
            QueueView()
                .environmentObject(player)
        }
        .sheet(isPresented: $isLyricsPresented) {
            if let track {
                LyricsSheet(track: track)
                    .environmentObject(player)
            }
        }
        .task(id: track?.artworkURL?.absoluteString ?? "none") {
            guard let url = track?.artworkURL else { return }
            guard let palette = await ColorExtractor.shared.palette(
                forKey: url.absoluteString,
                from: url
            ) else { return }
            withAnimation(.easeInOut(duration: 0.6)) {
                artworkPalette = palette
            }
        }
        .simultaneousGesture(dismissGesture)
        .onChange(of: track?.id) { _ in
            Haptics.light()
        }
        .alert("Видео не готово", isPresented: $showVideoError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(videoRenderer.failure ?? "Попробуйте ещё раз.")
        }
    }

    /// Плашка о нагреве: эффекты уже отключены, но пользователь должен
/// понимать, почему картинка стала статичной. На `.critical` — просьба
/// дать телефону остыть, воспроизведение уже стоит.
    @ViewBuilder
    private var heatNotice: some View {
        if device.shouldFreezeVisuals && !device.isHeatNoticeDismissed {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: device.shouldPauseForHeat ? "exclamationmark.triangle.fill" : "thermometer.high")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 3) {
                    Text(device.shouldPauseForHeat ? "Телефон перегрелся" : "Телефон нагрелся")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)

                    Text(
                        device.shouldPauseForHeat
                            ? "Воспроизведение остановлено. Дайте ему остыть."
                            : "Часть эффектов отключена до остывания."
                    )
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Button {
                    device.isHeatNoticeDismissed = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 26, height: 26)
                        .background { Circle().fill(Color.white.opacity(0.10)) }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Понятно")
            }
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.black.opacity(0.55))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            }
            .padding(.horizontal, 20)
            .padding(.top, 56)
            .transition(.opacity)
        }
    }

    /// Обычный и виниловый плеер живут в одном `DynamicBackground`: палитра
    /// обложки общая, переход — opacity + лёгкий scale.
    @ViewBuilder
    private var modeContent: some View {
        if mode == .vinyl {
            VinylPlayerView(
                palette: artworkPalette,
                onClose: { dismiss() },
                onExitVinyl: { playerModeRaw = PlayerMode.standard.rawValue }
            )
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
        } else {
            content
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(tone.tertiary.opacity(0.55))
                .frame(width: 36, height: 4)
                .padding(.top, 6)
                .accessibilityHidden(true)

            topBar

            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    artwork
                    WaveVisualizer(
                        isPlaying: player.isPlaying,
                        height: 64,
                        artworkURL: track?.artworkURL,
                        trackID: track?.id,
                        likeToken: likeBurstToken,
                        spectrum: player.spectrum,
                        currentTime: player.currentTime
                    )
                    .frame(maxWidth: 320)
                    titles
                    quickActions
                    if useWaveformScrubber {
                        WaveformScrubber(
                            fallbackDuration: track?.duration ?? 0,
                            accent: artworkPalette.primary.color
                        )
                    } else {
                        NowPlayingProgress(fallbackDuration: track?.duration ?? 0)
                    }
                    if abs(player.effectiveRate - 1) > 0.01 {
                        HStack(spacing: 4) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 9, weight: .bold))
                            Text(String(format: "×%.2f", player.effectiveRate))
                                .font(.caption2.monospacedDigit().weight(.semibold))
                        }
                        .foregroundStyle(tone.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .accessibilityLabel("Auto-DJ переход")
                    }
                    controls
                    actions
                    statusCard
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 30)
            }
        }
    }

    // MARK: - Верхняя панель

    private var topBar: some View {
        HStack {
            HStack(spacing: 8) {
                GlassIconButton("chevron.down", label: "Закрыть") {
                    dismiss()
                }

                sleepMenu
            }

            Spacer()

            HStack(spacing: 8) {
                videoButton
                shareButton
                queueButton
                modeButton

                GlassIconButton("mic", label: "Распознать трек") {
                    Haptics.light()
                    resumeAfterShazam = player.isPlaying
                    if player.isPlaying {
                        player.togglePlayPause()
                    }
                    isShazamPresented = true
                    Task { await shazam.start() }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    /// Сон-таймер: меню в верхней панели, на иконке — остаток минут.
    private var sleepMenu: some View {
        Menu {
            ForEach([5, 15, 30, 60], id: \.self) { minutes in
                Button("\(minutes) минут") {
                    Haptics.selection()
                    player.startSleepTimer(minutes: minutes)
                }
            }

            if player.sleepTimerEndsAt != nil {
                Button("Выключить таймер", role: .destructive) {
                    player.cancelSleepTimer()
                }
            }
        } label: {
            TimelineView(.periodic(from: Date(), by: 20)) { _ in
                ZStack(alignment: .topTrailing) {
                    Image(systemName: player.sleepTimerEndsAt == nil ? "moon" : "moon.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(player.sleepTimerEndsAt == nil ? tone.secondary : tone.primary)
                        .frame(width: 40, height: 40)
                        .background { Circle().fill(Color.white.opacity(0.06)) }
                        .overlay {
                            Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                        }

                    if let minutes = sleepRemainingMinutes {
                        Text("\(minutes)")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(tone.primary)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 16, minHeight: 16)
                            .background { Capsule().fill(Color.black.opacity(0.6)) }
                            .offset(x: 4, y: -4)
                    }
                }
            }
        }
        .accessibilityLabel(
            sleepRemainingMinutes.map { "Сон-таймер: \($0) минут" } ?? "Сон-таймер"
        )
    }

    private var sleepRemainingMinutes: Int? {
        guard let endsAt = player.sleepTimerEndsAt else { return nil }
        let remaining = endsAt.timeIntervalSinceNow
        guard remaining > 0 else { return 0 }
        return Int(ceil(remaining / 60))
    }

    /// Видео-открытка: рендер идёт секунды, поэтому на кнопке и в оверлее
/// виден прогресс, а плеер остаётся отзывчивым.
    @ViewBuilder
    private var videoButton: some View {
        if let track {
            Button {
                Haptics.light()
                prepareVideo(track)
            } label: {
                ZStack {
                    if videoRenderer.isRendering {
                        ProgressView()
                            .tint(tone.primary)
                    } else {
                        Image(systemName: "film")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(tone.primary)
                    }
                }
                .frame(width: 40, height: 40)
                .background { Circle().fill(Color.white.opacity(0.08)) }
                .overlay {
                    Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                }
            }
            .buttonStyle(PressableStyle(scale: 0.9))
            .disabled(videoRenderer.isRendering || isPreparingShare)
            .accessibilityLabel("Поделиться видео")
        }
    }

    private func prepareVideo(_ track: Track) {
        guard !videoRenderer.isRendering else { return }

        let asset = player.currentExportAsset
        let start = player.currentTime

        Task { @MainActor in
            do {
                let url = try await videoRenderer.render(
                    track: track,
                    asset: asset,
                    startTime: start
                )
                sharePayload = SharePayload(items: [url])
            } catch is CancellationError {
                return
            } catch {
                // Текст причины уже в videoRenderer.failure и в логе.
                showVideoError = true
            }
        }
    }

    /// Открытка рендерится в фоне: загрузка обложки и палитры может занять
    /// кадр-другой, поэтому на кнопке виден прогресс, а не «залипание».
    @ViewBuilder
    private var shareButton: some View {
        if let track {
            Button {
                Haptics.light()
                prepareShare(track)
            } label: {
                ZStack {
                    if isPreparingShare {
                        ProgressView()
                            .tint(tone.primary)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(tone.primary)
                    }
                }
                .frame(width: 40, height: 40)
                .background { Circle().fill(Color.white.opacity(0.08)) }
                .overlay {
                    Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                }
            }
            .buttonStyle(PressableStyle(scale: 0.9))
            .disabled(isPreparingShare)
            .accessibilityLabel("Поделиться треком")
        }
    }

    private func prepareShare(_ track: Track) {
        guard !isPreparingShare else { return }
        isPreparingShare = true

        Task { @MainActor in
            // Таймкод только для играющего трека: у остальных секунда чужая.
            let startAt = track.id == player.currentTrack?.id ? player.currentTime : nil
            let image = await ShareCardRenderer.image(for: track, startAt: startAt)
            isPreparingShare = false
            sharePayload = SharePayload(items: [image])
        }
    }

    /// Скорость и «похожее» под названием: редкие действия, но под рукой.
    /// Не в верхней панели — там уже пять кнопок, шестая не влезет на iPhone SE.
    private var quickActions: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(AudioPlayer.allowedRates, id: \.self) { rate in
                    Button {
                        Haptics.selection()
                        player.setPlaybackRate(rate)
                    } label: {
                        if abs(player.playbackRate - rate) < 0.01 {
                            Label(Self.rateTitle(rate), systemImage: "checkmark")
                        } else {
                            Text(Self.rateTitle(rate))
                        }
                    }
                }

                if player.playbackRate != 1 {
                    Button("Сбросить на 1×") {
                        Haptics.selection()
                        player.setPlaybackRate(1)
                    }
                }
            } label: {
                quickChip(
                    systemImage: "speedometer",
                    text: Self.rateTitle(player.playbackRate),
                    highlighted: player.playbackRate != 1
                )
            }
            .accessibilityLabel("Скорость воспроизведения")
            .accessibilityValue(Self.rateTitle(player.playbackRate))

            if let track {
                Button {
                    Haptics.selection()
                    // Сид `track:{id}` — сессия радио стартует от трека.
                    waveSession.start(from: track, seeds: ["track:\(track.id)"])
                } label: {
                    quickChip(
                        systemImage: "sparkles",
                        text: "Похожее",
                        highlighted: false
                    )
                }
                .accessibilityLabel("Играть похожее")
            }
        }
    }

    private func quickChip(systemImage: String, text: String, highlighted: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(highlighted ? tone.primary : tone.secondary)
        .padding(.horizontal, 11)
        .frame(height: 28)
        .background { Capsule().fill(Color.white.opacity(highlighted ? 0.14 : 0.07)) }
        .overlay {
            Capsule().strokeBorder(
                highlighted ? tone.primary.opacity(0.35) : Color.white.opacity(0.10),
                lineWidth: 1
            )
        }
    }

    private static func rateTitle(_ rate: Float) -> String {
        if abs(rate - rate.rounded()) < 0.01 {
            return "\(Int(rate.rounded()))×"
        }
        return String(format: "%.2g×", rate)
    }

    /// Очередь: badge с числом треков, чтобы было видно, что там что-то есть.
    private var queueButton: some View {
        Button {
            Haptics.selection()
            isQueuePresented = true
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "list.bullet")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tone.primary)
                    .frame(width: 40, height: 40)
                    .background { Circle().fill(Color.white.opacity(0.08)) }
                    .overlay {
                        Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                    }

                if !player.queue.isEmpty {
                    Text("\(player.queue.tracks.count)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(tone.primary)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 16, minHeight: 16)
                        .background { Capsule().fill(Color.black.opacity(0.6)) }
                        .offset(x: 4, y: -4)
                }
            }
        }
        .buttonStyle(PressableStyle(scale: 0.9))
        .accessibilityLabel("Очередь, \(player.queue.tracks.count) треков")
    }

    // MARK: - Обложка и подписи

    /// Переключение на винил. Режим сохраняется, поэтому следующий запуск
    /// плеера откроется в том же виде.
    private var modeButton: some View {
        Button {
            Haptics.selection()
            playerModeRaw = PlayerMode.vinyl.rawValue
        } label: {
            Image(systemName: "opticaldisc")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tone.primary)
                .frame(width: 40, height: 40)
                .background { Circle().fill(Color.white.opacity(0.08)) }
                .overlay {
                    Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                }
        }
        .buttonStyle(PressableStyle(scale: 0.9))
        .accessibilityLabel("Виниловый режим")
    }

    /// Системная кнопка выбора AirPlay-устройства.
    private var airPlayButton: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.08))
            Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
            AirPlayButton(tint: .white)
                .frame(width: 26, height: 26)
        }
        .frame(width: 40, height: 40)
        .accessibilityLabel("AirPlay")
    }

    /// Свайп вниз по экрану закрывает плеер. Порог и проверка вертикали
    /// не дают сработать на горизонтальном свайпе обложки.
    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                guard value.translation.height > 100,
                      abs(value.translation.height) > abs(value.translation.width)
                else { return }
                Haptics.light()
                dismiss()
            }
    }

    // MARK: - Обложка и подписи

    private var artwork: some View {
        ZStack {
            if let id = track?.id {
                coverImage(track?.artworkURL)
                    .id(id)
                    .transition(.opacity)
            } else {
                coverImage(nil)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: track?.id)
        .background { artworkGlow }
        .offset(x: artworkDrag * 0.22)
        .simultaneousGesture(artworkDragGesture)
        .onTapGesture(count: 2) {
            Haptics.light()
            player.togglePlayPause()
        }
        .padding(.top, 6)
    }

    private func coverImage(_ url: URL?) -> some View {
        CachedAsyncImage(url: url) {
            ZStack {
                Color.white.opacity(0.07)
                Image(systemName: "music.note")
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(.white.opacity(0.2))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 320)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.4), radius: 26, x: 0, y: 16)
    }

    /// Мягкое свечение из палитры обложки. Один слой: blur растеризуется
    /// через `drawingGroup`, пульсирует уже готовая текстура.
    private var artworkGlow: some View {
        RoundedRectangle(cornerRadius: 34, style: .continuous)
            .fill(artworkPalette.primary.color)
            .blur(radius: 40)
            .opacity(0.38)
            .padding(-10)
            .drawingGroup()
            .scaleEffect(player.isPlaying ? 1.05 : 1.0)
            .animation(
                .easeInOut(duration: 2).repeatForever(autoreverses: true),
                value: player.isPlaying
            )
            .allowsHitTesting(false)
    }

    /// Горизонтальный свайп по обложке: влево — следующий, вправо — предыдущий.
    /// Вертикальный жест отдаём `ScrollView`, поэтому обновляем смещение
    /// только когда движение явно горизонтальное.
    private var artworkDragGesture: some Gesture {
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

    private var titles: some View {
        VStack(spacing: 6) {
            Text(track?.title ?? "Ничего не играет")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(tone.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)

            artistLabel
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var artistLabel: some View {
        if let artistID = openableArtistID {
            Button {
                Haptics.selection()
                onOpenArtist(artistID)
            } label: {
                HStack(spacing: 4) {
                    Text(track?.artistLine ?? "Выберите трек в каталоге")
                        .font(.subheadline)
                        .lineLimit(1)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(tone.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(scale: 0.97))
            .accessibilityLabel("Открыть артиста")
        } else {
            Text(track?.artistLine ?? "Выберите трек в каталоге")
                .font(.subheadline)
                .foregroundStyle(tone.secondary)
                .lineLimit(1)
        }
    }

    /// У восстановленных треков (история) id артиста равен 0 — для него
    /// нет ручки, поэтому имя остаётся обычным текстом.
    private var openableArtistID: Int? {
        guard let id = track?.artists?.first?.id, id > 0 else { return nil }
        return id
    }

    // MARK: - Кнопки

    private var controls: some View {
        HStack(spacing: 24) {
            Button {
                player.toggleShuffle()
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(player.queue.isShuffled ? tone.primary : tone.tertiary)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(PressableStyle(scale: 0.9))
            .accessibilityLabel("Перемешать")

            controlButton("backward.fill", label: "Предыдущий") {
                Haptics.light()
                player.previous()
            }

            playPauseButton

            controlButton("forward.fill", label: "Следующий") {
                Haptics.light()
                player.next()
            }

            Button {
                player.cycleRepeat()
            } label: {
                Image(systemName: repeatSymbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(player.queue.repeatMode == .off ? tone.tertiary : tone.primary)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(PressableStyle(scale: 0.9))
            .accessibilityLabel("Повтор")
        }
        .frame(maxWidth: .infinity)
    }

    private var playPauseButton: some View {
        Button {
            Haptics.light()
            player.togglePlayPause()
        } label: {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay {
                        Circle().fill(Color.black.opacity(0.18))
                    }
                    .overlay {
                        Circle().strokeBorder(Color.white.opacity(0.28), lineWidth: 1)
                    }

                if player.isPlaying {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(tone.primary)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(tone.primary)
                        .offset(x: 2)
                }
            }
            .frame(width: 76, height: 76)
            .shadow(color: .black.opacity(0.35), radius: 18, x: 0, y: 10)
        }
        .buttonStyle(PressableStyle(scale: 0.94))
        .accessibilityLabel(player.isPlaying ? "Пауза" : "Играть")
    }

    private func controlButton(
        _ symbol: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(tone.primary)
                .frame(width: 48, height: 48)
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle(scale: 0.9))
        .accessibilityLabel(label)
    }

    private var repeatSymbol: String {
        player.queue.repeatMode == .one ? "repeat.1" : "repeat"
    }

    // MARK: - Действия

    @ViewBuilder
    private var actions: some View {
        if let track {
            HStack(spacing: 24) {
                dislikeButton(track)

                Button {
                    Haptics.selection()
                    isLyricsPresented = true
                } label: {
                    Image(systemName: "quote.bubble")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(tone.secondary)
                        .frame(width: 44, height: 44)
                        .background { Circle().fill(Color.white.opacity(0.06)) }
                        .overlay {
                            Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                        }
                }
                .buttonStyle(PressableStyle(scale: 0.9))
                .accessibilityLabel("Текст песни")

                LikeButton(
                    isLiked: likes.isLiked(track.id),
                    isPending: likes.isPending(track.id),
                    size: 44
                ) {
                    Task {
                        let liked = await likes.toggle(track)
                        if liked {
                            // Лайк уходит и в сессию волны: ротор учитывает
                            // его в подборе следующих треков.
                            waveSession.like(track)
                            likeBurstToken += 1
                        }
                    }
                }
                .accessibilityLabel(likes.isLiked(track.id) ? "Убрать из «Мне нравится»" : "Добавить в «Мне нравится»")

                airPlayButton
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// Дизлайк: просим ротор больше не предлагать похожее и переходим
    /// к следующему треку с плавным затуханием.
    private func dislikeButton(_ track: Track) -> some View {
        Button {
            Haptics.light()
            waveSession.dislike(track)
            player.fadeOutAndNext()
        } label: {
            Image(systemName: "hand.thumbsdown")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tone.secondary)
                .frame(width: 44, height: 44)
                .background { Circle().fill(Color.white.opacity(0.06)) }
                .overlay {
                    Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                }
        }
        .buttonStyle(PressableStyle(scale: 0.9))
        .accessibilityLabel("Не нравится")
        .accessibilityHint("Пропустить трек и подобрать другой")
    }

    // MARK: - Статус

    @ViewBuilder
    private var statusCard: some View {
        if case .failed(let error) = player.status, !error.isCancellation {
            ErrorStateCard(
                error: error,
                context: .track,
                cornerRadius: 22,
                padding: 16,
                footnote: "Это честный ответ сервера: клиент не обходит ограничения доступа."
            )
        } else if let notice = player.notice {
            GlassCard(cornerRadius: 22, padding: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(tone.secondary)

                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(tone.secondary)
                }
            }
        }
    }
}

/// Прогресс вынесен в отдельный View: `currentTime` меняется дважды в
/// секунду, и без изоляции перерисовывался бы весь экран с обложкой,
/// визуализатором и кнопками.
struct NowPlayingProgress: View {
    @EnvironmentObject private var player: AudioPlayer
    @Environment(\.contentTone) private var tone

    var fallbackDuration: Double = 0

    @AppStorage("player.showRemaining") private var showRemaining = true

    @State private var scrubValue: Double?
    @State private var isScrubbing = false
    @State private var lastHapticStep = -1

    var body: some View {
        let total = max(player.duration, fallbackDuration, 1)
        let shown = min(scrubValue ?? player.currentTime, total)

        return VStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { shown },
                    set: { value in
                        scrubValue = value

                        // Haptic каждые 5%: двадцать шагов на трек — не spam,
                        // но заметно, когда ведёшь палец.
                        let step = Int((value / total) * 20)
                        if step != lastHapticStep {
                            lastHapticStep = step
                            Haptics.selection()
                        }
                    }
                ),
                in: 0...total,
                onEditingChanged: { editing in
                    if editing {
                        isScrubbing = true
                        lastHapticStep = -1
                    } else {
                        player.seek(to: scrubValue ?? player.currentTime)
                        scrubValue = nil
                        isScrubbing = false
                        Haptics.light()
                    }
                }
            )
            .tint(tone.primary)
            // Плавный ход между тиками `currentTime` (2 раза в секунду).
            .animation(.linear(duration: 0.5), value: player.currentTime)
            .overlay(alignment: .top) {
                if isScrubbing {
                    Text(Self.timeText(shown))
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(tone.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background { Capsule().fill(Color.black.opacity(0.55)) }
                        .overlay {
                            Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                        }
                        .offset(y: -26)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }

            HStack {
                Text(Self.timeText(shown))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(tone.tertiary)

                Spacer()

                Button {
                    Haptics.selection()
                    showRemaining.toggle()
                } label: {
                    Text(
                        showRemaining
                            ? "-" + Self.timeText(max(total - shown, 0))
                            : Self.timeText(total)
                    )
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(tone.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    showRemaining ? "Показать длительность" : "Показать остаток"
                )
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isScrubbing)
    }

    private static func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
