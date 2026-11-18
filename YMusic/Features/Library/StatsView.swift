import SwiftUI

/// Экран статистики: часы, стрик и топы. Данные — из `ListeningStatsStore`
/// (время и счётчики) и из недавних треков плеера (чтобы по `id` получить
/// название и артиста: отдельный справочник не нужен).
struct StatsView: View {
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var stats: ListeningStatsStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.contentTone) private var tone

    var body: some View {
        ZStack {
            LiquidBackdrop()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    hoursCard
                    streakCard

                    topArtists
                    topTracks

                    if player.recents.isEmpty {
                        EmptyStateCard(
                            systemImage: "chart.bar",
                            title: "Пока пусто",
                            message: "Послушайте несколько треков — здесь появятся цифры."
                        )
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 40)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Блоки

    private var header: some View {
        HStack {
            Text("Статистика")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(tone.primary)

            Spacer(minLength: 0)

            GlassIconButton("xmark", label: "Закрыть") {
                dismiss()
            }
        }
    }

    private var hoursCard: some View {
        GlassCard(cornerRadius: 26, padding: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("ВСЕГО В МУЗЫКЕ")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(tone.tertiary)

                Text(hoursText)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(tone.primary)

                Text("\(Int(stats.snapshot.totalListeningSeconds / 60)) минут прослушано")
                    .font(.footnote)
                    .foregroundStyle(tone.secondary)
            }
        }
    }

    private var streakCard: some View {
        GlassCard(cornerRadius: 26, padding: 20) {
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ТЕКУЩИЙ СТРИК")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(tone.tertiary)

                    Text("🔥 \(stats.snapshot.currentStreak) \(dayWord(stats.snapshot.currentStreak))")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(tone.primary)
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 4) {
                    Text("РЕКОРД")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(tone.tertiary)

                    Text("\(stats.snapshot.longestStreak)")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(tone.primary)
                }
            }
        }
    }

    private var topArtists: some View {
        let artists = topArtistsList()
        return GlassCard(cornerRadius: 26, padding: 20) {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("Топ артистов")

                if artists.isEmpty {
                    emptyLine("Пока нет данных")
                } else {
                    ForEach(Array(artists.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 10) {
                            Text("\(index + 1)")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(tone.tertiary)
                                .frame(width: 18, alignment: .leading)

                            Text(item.name)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(tone.primary)
                                .lineLimit(1)

                            Spacer(minLength: 8)

                            Text("\(item.plays)")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(tone.secondary)
                        }
                    }
                }
            }
        }
    }

    private var topTracks: some View {
        let tracks = topTracksList()
        return GlassCard(cornerRadius: 26, padding: 20) {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("Топ треков")

                if tracks.isEmpty {
                    emptyLine("Пока нет данных")
                } else {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 10) {
                            Text("\(index + 1)")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(tone.tertiary)
                                .frame(width: 18, alignment: .leading)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(tone.primary)
                                    .lineLimit(1)

                                Text(item.artist)
                                    .font(.caption)
                                    .foregroundStyle(tone.secondary)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 8)

                            Text("\(item.plays)")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(tone.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Мелочи

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(tone.primary)
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(tone.tertiary)
    }

    private var hoursText: String {
        let hours = stats.hoursPlayed
        if hours >= 10 {
            return String(format: "%.0f ч", hours)
        }
        if hours >= 1 {
            return String(format: "%.1f ч", hours)
        }
        return String(format: "%.0f мин", stats.snapshot.totalListeningSeconds / 60)
    }

    private func dayWord(_ count: Int) -> String {
        let mod10 = count % 10
        let mod100 = count % 100
        if mod10 == 1, mod100 != 11 { return "день" }
        if (2...4).contains(mod10), !(12...14).contains(mod100) { return "дня" }
        return "дней"
    }

    // MARK: - Агрегация

    private struct ArtistEntry: Identifiable {
        let id: String
        let name: String
        let plays: Int
    }

    private struct TrackEntry: Identifiable {
        let id: Int
        let title: String
        let artist: String
        let plays: Int
    }

    /// Счётчики хранятся по `trackID`, поэтому названия артистов берём
    /// из недавних: они покрывают всё, что реально играло в этом сеансе.
    private func topArtistsList() -> [ArtistEntry] {
        let counts = stats.snapshot.playCountsByTrackID
        var totals: [String: Int] = [:]

        for track in player.recents {
            let plays = counts[String(track.id)] ?? 0
            guard plays > 0 else { continue }
            totals[track.artistLine, default: 0] += plays
        }

        return totals
            .map { ArtistEntry(id: $0.key, name: $0.key, plays: $0.value) }
            .sorted { $0.plays > $1.plays }
            .prefix(5)
            .map { $0 }
    }

    private func topTracksList() -> [TrackEntry] {
        let counts = stats.snapshot.playCountsByTrackID

        return player.recents
            .compactMap { track -> TrackEntry? in
                let plays = counts[String(track.id)] ?? 0
                guard plays > 0 else { return nil }
                return TrackEntry(
                    id: track.id,
                    title: track.title,
                    artist: track.artistLine,
                    plays: plays
                )
            }
            .sorted { $0.plays > $1.plays }
            .prefix(5)
            .map { $0 }
    }
}