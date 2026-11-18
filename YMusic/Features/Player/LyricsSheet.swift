import SwiftUI

/// Текст трека. Ручка `GET /tracks/{id}/lyrics` подтверждена: отдаёт ссылку
/// на файл, обычно LRC с таймкодами. Если таймкодов нет, показываем обычный
/// текст без подсветки. Строка с таймкодом по тапу делает seek.
struct LyricsSheet: View {
    let track: Track

    @EnvironmentObject private var player: AudioPlayer
    @Environment(\.dismiss) private var dismiss
    @Environment(\.contentTone) private var tone

    @State private var lines: [LyricLine] = []
    @State private var state: LoadState = .loading

    private enum LoadState {
        case loading
        case loaded
        case empty
        case failed
    }

    var body: some View {
        ZStack {
            LiquidBackdrop()

            VStack(spacing: 0) {
                GlassScreenHeader(
                    title: "Текст",
                    subtitle: track.title,
                    onClose: { dismiss() }
                )

                content
            }
        }
        .task(id: track.id) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            VStack(spacing: 12) {
                ForEach(0..<7, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(index == 0 ? 0.12 : 0.07))
                        .frame(height: 14)
                        .frame(maxWidth: index % 3 == 0 ? 240 : .infinity, alignment: .leading)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            .accessibilityHidden(true)

        case .loaded:
            lyricsScroll

        case .empty:
            VStack {
                EmptyStateCard(
                    systemImage: "quote.bubble",
                    title: "Текста нет",
                    message: "Для этого трека Яндекс не отдаёт текст. Попробуйте другой."
                )
                .padding(20)

                Spacer(minLength: 0)
            }

        case .failed:
            VStack(spacing: 14) {
                EmptyStateCard(
                    systemImage: "exclamationmark.bubble",
                    title: "Не загрузилось",
                    message: "Проверьте соединение и попробуйте ещё раз.",
                    actionTitle: "Повторить",
                    action: { Task { await load() } }
                )
                Spacer(minLength: 0)
            }
            .padding(20)
        }
    }

    private var lyricsScroll: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(lines) { line in
                        Text(line.text)
                            .font(
                                .system(
                                    size: line.id == currentLineID ? 20 : 17,
                                    weight: line.id == currentLineID ? .bold : .medium,
                                    design: .rounded
                                )
                            )
                            .foregroundStyle(
                                line.id == currentLineID ? tone.primary : tone.tertiary
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard let time = line.time else { return }
                                Haptics.selection()
                                player.seek(to: time)
                            }
                            .id(line.id)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 60)
                .animation(.easeInOut(duration: 0.25), value: currentLineID)
            }
            .onChange(of: currentLineID) { id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    /// Последняя строка, время которой уже наступило. `nil` — таймкодов нет.
    private var currentLineID: Int? {
        guard lines.contains(where: { $0.time != nil }) else { return nil }
        return lines.last { line in
            guard let time = line.time else { return false }
            return time <= player.currentTime
        }?.id
    }

    private func load() async {
        state = .loading
        lines = []

        do {
            guard let raw = try await APIManager.shared.lyrics(trackID: track.id) else {
                state = .empty
                return
            }

            let parsed = LyricsParser.parse(raw)
            lines = parsed
            state = parsed.isEmpty ? .empty : .loaded
        } catch is CancellationError {
            return
        } catch {
            state = .failed
        }
    }
}

struct LyricLine: Identifiable, Equatable {
    let id: Int
    let time: Double?
    let text: String
}

/// Разбор LRC: `[mm:ss.xx] строка`. Строки без таймкодов тоже сохраняем —
/// тогда это просто текст без подсветки.
enum LyricsParser {
    private static let timestampPattern = "\\[(\\d{1,2}):(\\d{2})(?:\\.(\\d{1,3}))?\\]"

    static func parse(_ raw: String) -> [LyricLine] {
        let regex = try? NSRegularExpression(pattern: timestampPattern)
        var result: [LyricLine] = []
        var nextID = 0

        for rawLine in raw.components(separatedBy: .newlines) {
            var time: Double?
            var text = rawLine

            if let regex {
                let range = NSRange(rawLine.startIndex..., in: rawLine)
                let matches = regex.matches(in: rawLine, range: range)

                if let last = matches.last {
                    let minutes = Int(component(1, of: last, in: rawLine, regex: regex) ?? "") ?? 0
                    let seconds = Int(component(2, of: last, in: rawLine, regex: regex) ?? "") ?? 0
                    let fraction = component(3, of: last, in: rawLine, regex: regex)
                    let milliseconds: Double

                    if let fraction {
                        // 2 знака — сотые, 3 — миллисекунды.
                        let value = Double(fraction) ?? 0
                        milliseconds = fraction.count == 3 ? value / 1000 : value / 100
                    } else {
                        milliseconds = 0
                    }

                    time = Double(minutes * 60 + seconds) + milliseconds
                    text = regex.stringByReplacingMatches(
                        in: rawLine,
                        range: range,
                        withTemplate: ""
                    )
                }
            }

            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            result.append(LyricLine(id: nextID, time: time, text: trimmed))
            nextID += 1
        }

        return result
    }

    private static func component(
        _ index: Int,
        of match: NSTextCheckingResult,
        in string: String,
        regex: NSRegularExpression
    ) -> String? {
        let range = match.range(at: index)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: string) else {
            return nil
        }
        return String(string[swiftRange])
    }
}