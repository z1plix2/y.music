import SwiftUI

/// Лист «Добавить в плейлист»: список своих плейлистов и создание нового.
/// Открывается из контекстного меню строки трека.
struct AddToPlaylistSheet: View {
    let userID: Int
    let track: Track

    @Environment(\.dismiss) private var dismiss
    @Environment(\.contentTone) private var tone

    @State private var playlists: [Playlist] = []
    @State private var isLoading = true
    @State private var loadError: APIError?
    @State private var actionError: APIError?
    @State private var busyKind: Int?
    @State private var isCreating = false
    @State private var isCreatePresented = false
    @State private var newTitle = ""

    private let editor: any PlaylistEditingProviding = YandexPlaylistEditor.shared

    var body: some View {
        ZStack {
            LiquidBackdrop()

            VStack(spacing: 0) {
                header
                content
            }
        }
        .task { await load() }
        .alert("Новый плейлист", isPresented: $isCreatePresented) {
            TextField("Название", text: $newTitle)
            Button("Создать") {
                let title = newTitle
                newTitle = ""
                Task { await createAndAdd(title: title) }
            }
            Button("Отмена", role: .cancel) { newTitle = "" }
        } message: {
            Text("Создадим плейлист и сразу добавим в него этот трек.")
        }
        .alert(
            "Не удалось добавить",
            isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError?.humanizedDescription(context: .playlist) ?? "")
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            GlassScreenHeader(
                title: "В плейлист",
                subtitle: track.title,
                onClose: { dismiss() }
            )

            GlassButton(
                "Новый плейлист",
                systemImage: "plus",
                isEnabled: !isCreating,
                fullWidth: true
            ) {
                Haptics.selection()
                isCreatePresented = true
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            VStack(spacing: 12) {
                ProgressView().tint(tone.secondary)
                Text("Загружаем плейлисты…")
                    .font(.footnote)
                    .foregroundStyle(tone.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError {
            VStack {
                ErrorStateCard(error: loadError, context: .playlist) {
                    Task { await load() }
                }
                .padding(20)
                Spacer(minLength: 0)
            }
        } else if playlists.isEmpty {
            VStack {
                EmptyStateCard(
                    systemImage: "music.note.list",
                    title: "Нет плейлистов",
                    message: "Создайте плейлист кнопкой выше — трек добавим сразу.",
                    actionTitle: "Создать",
                    actionSystemImage: "plus",
                    action: { isCreatePresented = true }
                )
                .padding(20)
                Spacer(minLength: 0)
            }
        } else {
            ScrollView(showsIndicators: false) {
                GlassCard(cornerRadius: 24, padding: 8) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(playlists.enumerated()), id: \.element.id) { index, playlist in
                            row(playlist)

                            if index < playlists.count - 1 {
                                Rectangle()
                                    .fill(Color.white.opacity(0.07))
                                    .frame(height: 0.5)
                                    .padding(.leading, 68)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
        }
    }

    private func row(_ playlist: Playlist) -> some View {
        Button {
            Haptics.selection()
            Task { await add(to: playlist) }
        } label: {
            HStack(spacing: 12) {
                CachedAsyncImage(url: playlist.artworkURL) {
                    ZStack {
                        Color.white.opacity(0.08)
                        Image(systemName: "music.note.list")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                }
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(playlist.title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(tone.primary)
                        .lineLimit(1)

                    Text(playlist.subtitle)
                        .font(.caption)
                        .foregroundStyle(tone.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if busyKind == playlist.kind {
                    ProgressView().tint(tone.secondary)
                } else {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(tone.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.99))
        .disabled(busyKind != nil || isCreating)
    }

    // MARK: - Действия

    private func load() async {
        isLoading = true
        loadError = nil
        do {
            playlists = try await APIManager.shared.playlists(userID: userID)
        } catch let error as APIError {
            guard !error.isCancellation else { return }
            loadError = error
        } catch {
            loadError = .unknown(error.localizedDescription)
        }
        isLoading = false
    }

    private func add(to playlist: Playlist) async {
        busyKind = playlist.kind

        do {
            let revision = try await revision(for: playlist.kind)
            try await editor.addToPlaylist(
                userID: userID,
                kind: playlist.kind,
                tracks: [track],
                revision: revision
            )
            Haptics.success()
            dismiss()
        } catch let error as APIError {
            if !error.isCancellation { actionError = error }
        } catch {
            actionError = .unknown(error.localizedDescription)
        }

        busyKind = nil
    }

    private func createAndAdd(title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isCreating = true
        do {
            let playlist = try await editor.createPlaylist(userID: userID, title: trimmed)
            if let revision = playlist.revision {
                try await editor.addToPlaylist(
                    userID: userID,
                    kind: playlist.kind,
                    tracks: [track],
                    revision: revision
                )
            }
            Haptics.success()
            dismiss()
        } catch let error as APIError {
            if !error.isCancellation { actionError = error }
        } catch {
            actionError = .unknown(error.localizedDescription)
        }
        isCreating = false
    }

    /// Список плейлистов не всегда отдаёт `revision`; перед изменением
    /// перезапрашиваем конкретный плейлист за актуальной версией.
    private func revision(for kind: Int) async throws -> Int {
        let page = try await APIManager.shared.playlistTracks(userID: userID, kind: kind)
        guard let revision = page.revision else {
            throw APIError.unavailable("Сервер не отдал версию плейлиста")
        }
        return revision
    }
}
