import SwiftUI
import UniformTypeIdentifiers

/// Preview each voice reading a short meditation line, then choose a default.
struct VoiceSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var preview = PreviewPlayer()

    var body: some View {
        Form {
            if model.voices.isEmpty {
                Section {
                    HStack {
                        ProgressView()
                        Text("Loading voices…").foregroundStyle(Palette.secondaryInk)
                    }
                }
            } else {
                Section {
                    ForEach(model.voices) { voice in
                        VoiceRow(voice: voice,
                                 isSelected: model.settings?.voiceId == voice.id,
                                 isPlaying: preview.playingID == voice.id,
                                 isLoading: preview.loadingID == voice.id,
                                 onPreview: {
                                     Task {
                                         await preview.toggle(id: voice.id, path: voice.previewUrl,
                                                              api: model.api, sessionPlayer: model.player)
                                     }
                                 },
                                 onSelect: {
                                     Task { await model.updateSettings { $0.voiceId = voice.id } }
                                 })
                    }
                } footer: {
                    if model.voices.contains(where: { $0.provider == "demo" }) {
                        Text("These are demo voices (offline, open-source). Add an ElevenLabs key on your server for natural, expressive narration.")
                    } else {
                        Text("Narration by ElevenLabs. New sessions use the voice you choose.")
                    }
                }
                .listRowBackground(Palette.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .presentBackground()
        .navigationTitle("Voice")
        .task { await model.refreshVoicesAndMusic() }
        .onDisappear { preview.stop() }
    }
}

private struct VoiceRow: View {
    let voice: Voice
    let isSelected: Bool
    let isPlaying: Bool
    let isLoading: Bool
    let onPreview: () -> Void
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onPreview) {
                ZStack {
                    Circle().fill(Palette.accentSoft).frame(width: 38, height: 38)
                    if isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.ink)
                    }
                }
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isPlaying ? "Stop preview of \(voice.name)" : "Preview \(voice.name)")
            .accessibilityIdentifier("previewVoice_\(voice.id)")

            Button(action: onSelect) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(voice.name).foregroundStyle(Palette.ink)
                            if voice.provider == "demo" { DemoBadge() }
                        }
                        Text(voice.description)
                            .font(Typography.caption)
                            .foregroundStyle(Palette.secondaryInk)
                    }
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark").foregroundStyle(Palette.accent)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
        .padding(.vertical, 4)
    }
}

/// Background music: built-in ambient tracks plus anything you upload from Suno.
struct MusicSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var preview = PreviewPlayer()
    @State private var importing = false
    @State private var uploading = false
    @State private var uploadError: String?

    private var selectedID: String { model.settings?.musicTrackId ?? "auto" }

    var body: some View {
        Form {
            Section {
                Button {
                    Task { await model.updateSettings { $0.musicTrackId = "auto" } }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Choose for me").foregroundStyle(Palette.ink)
                            Text("Rotates gently through the tracks switched on below")
                                .font(Typography.caption)
                                .foregroundStyle(Palette.secondaryInk)
                        }
                        Spacer()
                        if selectedID == "auto" {
                            Image(systemName: "checkmark").foregroundStyle(Palette.accent)
                        }
                    }
                }
            }
            .listRowBackground(Palette.surface)

            Section {
                ForEach(model.tracks) { track in
                    TrackRow(track: track,
                             isSelected: selectedID == track.id,
                             isPlaying: preview.playingID == track.id,
                             isLoading: preview.loadingID == track.id,
                             onPreview: {
                                 Task {
                                     await preview.toggle(id: track.id, path: track.previewUrl,
                                                          api: model.api, sessionPlayer: model.player)
                                 }
                             },
                             onSelect: {
                                 Task { await model.updateSettings { $0.musicTrackId = track.id } }
                             },
                             onToggle: { enabled in
                                 Task { await setEnabled(track, enabled) }
                             })
                    .deleteDisabled(!track.isUpload)
                }
                .onDelete { offsets in
                    let targets = offsets.map { model.tracks[$0] }.filter(\.isUpload)
                    Task {
                        for track in targets { await delete(track) }
                    }
                }
            } header: {
                Text("Tracks")
            } footer: {
                Text("Music fades in and out and dips softly whenever the voice speaks.")
            }
            .listRowBackground(Palette.surface)

            Section {
                Button {
                    importing = true
                } label: {
                    HStack {
                        Label("Add a track from Suno…", systemImage: "square.and.arrow.down")
                        Spacer()
                        if uploading { ProgressView() }
                    }
                }
                .disabled(uploading)
                .accessibilityIdentifier("uploadTrackButton")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Download an instrumental from Suno (MP3, M4A or WAV), save it to Files, then add it here. Check your Suno plan allows the use you intend.")
                    if let uploadError {
                        Text(uploadError).foregroundStyle(Palette.accent)
                    }
                }
            }
            .listRowBackground(Palette.surface)
        }
        .scrollContentBackground(.hidden)
        .presentBackground()
        .navigationTitle("Music")
        .task { await model.refreshVoicesAndMusic() }
        .onDisappear { preview.stop() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.mp3, .mpeg4Audio, .wav, .audio]) { result in
            switch result {
            case .success(let url):
                Task { await upload(url) }
            case .failure(let error):
                uploadError = error.localizedDescription
            }
        }
    }

    private func upload(_ url: URL) async {
        guard let api = model.api else { return }
        uploading = true
        uploadError = nil
        defer { uploading = false }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let title = url.deletingPathExtension().lastPathComponent
        do {
            _ = try await api.uploadTrack(fileURL: url, title: title)
            await model.refreshVoicesAndMusic()
        } catch {
            uploadError = "Upload didn't work: \(error.localizedDescription)"
        }
    }

    private func setEnabled(_ track: MusicTrack, _ enabled: Bool) async {
        guard let api = model.api else { return }
        do {
            _ = try await api.updateTrack(id: track.id, enabled: enabled)
            await model.refreshVoicesAndMusic()
        } catch {
            uploadError = error.localizedDescription
        }
    }

    private func delete(_ track: MusicTrack) async {
        guard let api = model.api else { return }
        do {
            try await api.deleteTrack(id: track.id)
            if selectedID == track.id {
                await model.updateSettings { $0.musicTrackId = "auto" }
            }
            await model.refreshVoicesAndMusic()
        } catch {
            uploadError = error.localizedDescription
        }
    }
}

private struct TrackRow: View {
    let track: MusicTrack
    let isSelected: Bool
    let isPlaying: Bool
    let isLoading: Bool
    let onPreview: () -> Void
    let onSelect: () -> Void
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onPreview) {
                ZStack {
                    Circle().fill(Palette.accentSoft).frame(width: 38, height: 38)
                    if isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.ink)
                    }
                }
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isPlaying ? "Stop preview" : "Preview \(track.title)")

            Button(action: onSelect) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                        Text("\(track.license) · \(TimeFormat.clock(track.durationSeconds))")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.secondaryInk)
                            .lineLimit(1)
                    }
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark").foregroundStyle(Palette.accent)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)

            Toggle("", isOn: Binding(get: { track.enabled }, set: onToggle))
                .labelsHidden()
                .tint(Palette.sage)
                .accessibilityLabel("Use \(track.title) in rotation")
        }
        .padding(.vertical, 4)
    }
}
