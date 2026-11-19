import SwiftUI

/// Фильтр умных списков истории.
enum HistoryFilter: String, CaseIterable, Identifiable {
    case all
    case top
    case forgotten

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "Все"
        case .top: return "Топ"
        case .forgotten: return "Забытое"
        }
    }
}

/// История прослушиваний: «Все» — по дням, «Топ» — 20 самых частых,
/// «Забытое» — лайкнутое, что не играло больше 30 дней.
///
/// Списки ленивые: до 200 записей истории и до 200 треков в «Забытом»,
/// поэтому `LazyVStack`, а не `VStack`.
struct HistoryView: View {
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var likes: LikeStore
    @EnvironmentObject private var stats: ListeningStatsStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.contentTone) private var tone

    @StateObject private var history = PlayHistoryStore.shared

    @State private var filter: HistoryFilter
    @State private var topTracks: [Track] = []
    @State private var forgottenTracks: [Track] = []
    @State private var topPlays: [Int: Int] = [:]
    @State private var isLoading = false
    @State private var error: APIError?
    @State private var loadedFilters: Set<HistoryFilter> = []
    @State private var showClearConfirmation = false

    private static let forgottenAfterDays = 30
    private static let topLimit = 20
    private static let forgottenLimit = 200
    private static let batchSize = 100

    init(initialFilter: HistoryFilter = .all) {
        _filter = State(initialValue: initialFilter)
    }

    var body: some View {
        ZStack {
            LiquidBackdrop()

            VStack(spacing: 0) {
                header
                filterPicker

                if filter == .all, !history.entries.isEmpty {
                    historyActions
                }

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {
                        content
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 40)
                }
            }
        }
        .task(id: filter) { await loadIfNeeded(filter) }
        .confirmationDialog(
            "Очистить историю?",
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Очистить", role: .destructive) {
                Haptics.light()
                history.clear()
            }

            Button("Отмена", role: .cancel) { }
        } message: {
            Text("Списки «Все» и «Забытое» опустеют. Лайки и статистика останутся.")
        }
        .onAppear {
            // «Забытое» существует только при достаточном числе лайков:
            // иначе список пуст и фильтр только путает.
            if filter == .forgotten, !showsForgotten {
                filter = .all
            }
        }
    }

    // MARK: - Шапка

    private var header: some View {
        GlassScreenHeader(
            title: "История",
            subtitle: subtitle,
            onClose: { dismiss() }
        )
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private var subtitle: String? {
        switch filter {
        case .all:
            guard !history.entries.isEmpty else { return nil }
            return "\(history.entries.count) из \(PlayHistoryStore.limit)"
        case .top:
            guard !topTracks.isEmpty else { return nil }
            return "20 самых частых"
        case .forgotten:
            guard !forgottenTracks.isEmpty else { return nil }
            return "\(forgottenTracks.count) треков"
        }
    }

    private var filterPicker: some View {
        Picker("Список", selection: $filter) {
            ForEach(availableFilters) { item in
                Text(item.title).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
        .onChange(of: filter) { _ in
            Haptics.selection()
        }
    }

    /// Действия над всей историей: запустить перемешанную копию или очистить.
    /// Видны только на фильтре «Все» — «Топ» и «Забытое» собираются иначе.
    private var historyActions: some View {
        HStack(spacing: 16) {
            Button {
                Haptics.selection()
                let tracks = history.entries.map { $0.track.track }
                player.play(tracks: tracks.shuffled(), startAt: 0)
            } label: {
                Label("Перемешать", systemImage: "shuffle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tone.primary)
            }

            Button {
                Haptics.selection()
                showClearConfirmation = true
            } label: {
                Label("Очистить", systemImage: "trash")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.red.opacity(0.9))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
    }

    private var availableFilters: [HistoryFilter] {
        showsForgotten ? HistoryFilter.allCases : [.all, .top]
    }

    private var showsForgotten: Bool {
        likes.likedIDs.count >= 20
    }

    // MARK: - Контент

    @ViewBuilder
    private var content: some View {
        switch filter {
        case .all:
            allContent
        case .top:
            listContent(
                tracks: topTracks,
                emptyImage: "chart.bar",
                emptyTitle: "Топ пока пуст",
                emptyMessage: "Послушайте несколько треков — счётчик проигрываний подскажет, что вы любите."
            )
        case .forgotten:
            listContent(
                tracks: forgottenTracks,
                emptyImage: "clock.arrow.circlepath",
                emptyTitle: "Забытых нет",
                emptyMessage: "Все лайкнутые треки играли за последние 30 дней — так держать."
            )
        }
    }

    @ViewBuilder
    private var allContent: some View {
        if isLoading {
            skeleton
        } else if history.entries.isEmpty {
            EmptyStateCard(
                systemImage: "clock",
                title: "История пуста",
                message: "Включите любой трек — здесь появится, что и когда вы слушали."
            )
        } else {
            ForEach(historyGroups) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(group.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tone.tertiary)
                        .textCase(.uppercase)
                        .padding(.leading, 4)

                    trackList(group.entries.map { $0.track.track })
                }
            }
        }
    }

    // MARK: - Списки

    @ViewBuilder
    private func listContent(
        tracks: [Track],
        emptyImage: String,
        emptyTitle: String,
        emptyMessage: String
    ) -> some View {
        if isLoading {
            skeleton
        } else if let error, tracks.isEmpty {
            ErrorStateCard(error: error, context: .track) {
                Task {
                    loadedFilters.remove(filter)
                    await loadIfNeeded(filter)
                }
            }
        } else if tracks.isEmpty {
            EmptyStateCard(
                systemImage: emptyImage,
                title: emptyTitle,
                message: emptyMessage
            )
        } else {
            trackList(tracks)
        }
    }

    private func trackList(_ tracks: [Track]) -> some View {
        GlassCard(cornerRadius: 24, padding: 8) {
            LazyVStack(spacing: 0) {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    let isCurrent = player.currentTrack?.id == track.id

                    TrackRowView(
                        track: track,
                        isCurrent: isCurrent,
                        isPlaying: isCurrent && player.isPlaying,
                        onTap: { player.play(track: track, in: tracks) }
                    )
                    .overlay(alignment: .trailing) {
                        if filter == .top, let plays = topPlays[track.id] {
                            Text("\(plays)×")
                                .font(.caption2.monospacedDigit().weight(.semibold))
                                .foregroundStyle(tone.tertiary)
                                .padding(.trailing, 52)
                                .allowsHitTesting(false)
                        }
                    }

                    if index < tracks.count - 1 {
                        Rectangle()
                            .fill(Color.white.opacity(0.07))
                            .frame(height: 0.5)
                            .padding(.leading, 68)
                    }
                }
            }
        }
    }

    private var skeleton: some View {
        GlassCard(cornerRadius: 24, padding: 8) {
            VStack(spacing: 0) {
                ForEach(0..<6, id: \.self) { _ in
                    HistorySkeletonRow()
                }
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - Группировка

    private struct HistoryGroup: Identifiable {
        let id: String
        let title: String
        let entries: [HistoryEntry]
    }

    private var historyGroups: [HistoryGroup] {
        var buckets: [String: [HistoryEntry]] = [:]

        for entry in history.entries {
            buckets[Self.groupTitle(for: entry.lastPlayedAt), default: []].append(entry)
        }

        return ["Сегодня", "Вчера", "На этой неделе", "Раньше"].compactMap { title in
            guard let items = buckets[title], !items.isEmpty else { return nil }
            return HistoryGroup(id: title, title: title, entries: items)
        }
    }

    private static func groupTitle(for date: Date) -> String {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: Date())
        let days = calendar.dateComponents([.day], from: start, to: today).day ?? 365

        if days <= 0 { return "Сегодня" }
        if days == 1 { return "Вчера" }
        if days < 7 { return "На этой неделе" }
        return "Раньше"
    }

    // MARK: - Загрузка

    private func loadIfNeeded(_ filter: HistoryFilter) async {
        guard !loadedFilters.contains(filter) else { return }
        guard filter != .forgotten || showsForgotten else { return }

        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            switch filter {
            case .all:
                break

            case .top:
                await loadTop()

            case .forgotten:
                try await loadForgotten()
            }

            loadedFilters.insert(filter)
        } catch is CancellationError {
            return
        } catch let apiError as APIError {
            error = apiError
        } catch {
            self.error = .unknown(error.localizedDescription)
        }
    }

    private func loadTop() async {
        let ranked = stats.snapshot.playCountsByTrackID
            .compactMap { key, value -> (id: Int, plays: Int)? in
                guard let id = Int(key) else { return nil }
                return (id, value)
            }
            .sorted { $0.plays > $1.plays }
            .prefix(Self.topLimit)

        let ids = ranked.map(\.id)
        topPlays = Dictionary(uniqueKeysWithValues: ranked.map { ($0.id, $0.plays) })

        guard !ids.isEmpty else {
            topTracks = []
            return
        }

        let fetched = try? await Self.tracks(ids: ids)
        let local = Dictionary(
            (player.recents + history.entries.map { $0.track.track }).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // Сохраняем порядок по числу прослушиваний: API порядок не гарантирует.
        topTracks = ids.compactMap { id in
            fetched?.first { $0.id == id } ?? local[id]
        }
    }

    private func loadForgotten() async throws {
        let liked = likes.likedIDs
        guard liked.count >= 20 else {
            forgottenTracks = []
            return
        }

        let candidates = liked
            .filter { (history.daysSincePlayed($0) ?? Int.max) > Self.forgottenAfterDays }
            .sorted { lhs, rhs in
                // Никогда не игравшие — первыми, дальше самые старые.
                let left = history.lastPlayedAt(for: lhs) ?? .distantPast
                let right = history.lastPlayedAt(for: rhs) ?? .distantPast
                return left < right
            }
            .prefix(Self.forgottenLimit)

        guard !candidates.isEmpty else {
            forgottenTracks = []
            return
        }

        forgottenTracks = try await Self.tracks(ids: Array(candidates))
    }

    /// `/tracks?track-ids=` принимает не больше 100 id: режем на пачки.
    private static func tracks(ids: [Int]) async throws -> [Track] {
        guard !ids.isEmpty else { return [] }

        var result: [Track] = []
        var seen = Set<Int>()

        for start in stride(from: 0, to: ids.count, by: batchSize) {
            let chunk = Array(ids[start..<min(start + batchSize, ids.count)])
            let tracks = try await APIManager.shared.tracks(ids: chunk)

            for track in tracks where !seen.contains(track.id) {
                seen.insert(track.id)
                result.append(track)
            }
        }

        return result
    }
}

/// Скелетон строки: та же геометрия, что у `TrackRowView`.
private struct HistorySkeletonRow: View {
    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(0.12))
                    .frame(height: 10)

                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(0.07))
                    .frame(width: 90, height: 8)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }
}