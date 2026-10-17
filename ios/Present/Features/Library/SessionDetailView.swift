import SwiftUI

struct SessionDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let sessionID: String

    @State private var showingReflection = false
    @State private var confirmingDelete = false
    @State private var editingEntry: JournalEntry?

    private var session: Session? {
        model.librarySessions.first { $0.id == sessionID }
            ?? model.downloads.downloadedSessions().first { $0.id == sessionID }
    }

    var body: some View {
        Group {
            if let session {
                content(session)
            } else {
                Text("This session is no longer here.")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.secondaryInk)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .presentBackground()
        .navigationBarTitleDisplayMode(.inline)
    }

    private func content(_ session: Session) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header(session)

                if session.status == .ready {
                    HStack {
                        Spacer()
                        PrimaryPlayButton(isPreparing: model.preparingSessionID == session.id, size: 88) {
                            Task { await model.play(session) }
                        }
                        .accessibilityIdentifier("detailPlayButton")
                        Spacer()
                    }
                }

                actions(session)

                journalSection(session)

                if let transcript = session.transcript, !transcript.isEmpty {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(transcript.enumerated()), id: \.offset) { _, line in
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(TimeFormat.clock(line.startSeconds))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(Palette.secondaryInk)
                                        .frame(width: 40, alignment: .leading)
                                    Text(line.text)
                                        .font(Typography.callout)
                                        .foregroundStyle(Palette.ink)
                                }
                            }
                        }
                        .padding(.top, 12)
                    } label: {
                        Text("Read the words")
                            .font(Typography.callout)
                            .foregroundStyle(Palette.ink)
                    }
                    .tint(Palette.secondaryInk)
                }

                if let providers = session.providers {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Made with").eyebrowStyle()
                        Text("Script: \(providers.script)")
                        Text("Voice: \(session.voiceName ?? providers.voice)")
                        Text("Music: \(session.musicTitle ?? providers.music)")
                    }
                    .font(Typography.caption)
                    .foregroundStyle(Palette.secondaryInk)
                }
            }
            .padding(24)
        }
        .sheet(isPresented: $showingReflection) {
            ReflectionView(session: session, mode: .fromLibrary) {
                showingReflection = false
            }
            .environment(model)
            .presentationBackground(Palette.background)
        }
        .sheet(item: $editingEntry) { entry in
            JournalEditSheet(entry: entry)
                .environment(model)
                .presentationBackground(Palette.background)
        }
        .confirmationDialog("Delete this session?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete session", role: .destructive) {
                Task {
                    await model.deleteSession(session)
                    dismiss()
                }
            }
        } message: {
            Text("Its audio is removed from your server and this iPhone. Journal entries stay.")
        }
    }

    private func header(_ session: Session) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ThemeLine(theme: session.theme, minutes: session.durationMinutes)
                if session.demo { DemoBadge() }
            }
            Text(session.displayTitle)
                .font(Typography.display)
                .foregroundStyle(Palette.ink)
            if let day = session.day {
                Text(TimeFormat.longDate(day))
                    .font(Typography.caption)
                    .foregroundStyle(Palette.secondaryInk)
            }
            if let summary = session.summary {
                Text(summary)
                    .font(Typography.body)
                    .foregroundStyle(Palette.secondaryInk)
                    .lineSpacing(3)
                    .padding(.top, 4)
            }
            if session.status == .failed {
                Text(session.statusDetail ?? "This session didn't finish preparing.")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.secondaryInk)
            } else if session.status.isInProgress {
                Text(session.statusDetail ?? "Still preparing…")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.secondaryInk)
            }
        }
    }

    private func actions(_ session: Session) -> some View {
        VStack(spacing: 0) {
            ActionRow(title: session.favorite ? "Favourite" : "Add to favourites",
                      symbol: session.favorite ? "heart.fill" : "heart",
                      tint: session.favorite ? Palette.accent : Palette.ink) {
                Task { await model.toggleFavorite(session) }
            }
            .accessibilityIdentifier("detailFavoriteButton")

            if session.status == .ready && !model.isBundledDemo(session) {
                Divider().overlay(Palette.hairline)
                if model.downloads.isDownloading(session.id) {
                    HStack {
                        ProgressView()
                        Text("Downloading…")
                            .font(Typography.callout)
                            .foregroundStyle(Palette.secondaryInk)
                        Spacer()
                    }
                    .padding(.vertical, 14)
                } else if model.isAvailableOffline(session) {
                    ActionRow(title: "Remove download", symbol: "arrow.down.circle.fill", tint: Palette.sage) {
                        model.removeDownload(session)
                    }
                } else {
                    ActionRow(title: "Download for offline", symbol: "arrow.down.circle", tint: Palette.ink) {
                        Task { await model.download(session) }
                    }
                    .accessibilityIdentifier("downloadButton")
                }
            }

            if !model.isBundledDemo(session) && model.isConnected {
                Divider().overlay(Palette.hairline)
                ActionRow(title: "Delete session", symbol: "trash", tint: Palette.secondaryInk) {
                    confirmingDelete = true
                }
                .accessibilityIdentifier("deleteSessionButton")
            }
        }
        .padding(.horizontal, 16)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
    }

    @ViewBuilder
    private func journalSection(_ session: Session) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Reflection").eyebrowStyle()
                Spacer()
                Button {
                    showingReflection = true
                } label: {
                    Label("Write", systemImage: "square.and.pencil")
                        .font(Typography.callout)
                }
                .tint(Palette.accent)
                .accessibilityIdentifier("writeReflectionButton")
            }

            Text(session.fallbackReflectionQuestion)
                .font(Typography.title3)
                .italic()
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)

            let entries = model.journal.entries(for: session.id)
            if !entries.isEmpty {
                if model.journalNeedsUnlock {
                    Button {
                        Task { _ = await model.unlockJournal() }
                    } label: {
                        Label("Unlock to read your journal", systemImage: "lock")
                            .font(Typography.callout)
                    }
                    .tint(Palette.accent)
                    .accessibilityIdentifier("unlockJournalButton")
                } else {
                    ForEach(entries) { entry in
                        JournalEntryCard(entry: entry, showsSession: false) {
                            editingEntry = entry
                        } onDelete: {
                            model.journal.delete(entry.id)
                        }
                    }
                }
            }
        }
    }
}

private struct ActionRow: View {
    let title: String
    let symbol: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .frame(width: 24)
                Text(title)
                    .font(Typography.body)
                    .foregroundStyle(Palette.ink)
                Spacer()
            }
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
