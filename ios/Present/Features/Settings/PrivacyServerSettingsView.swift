import SwiftUI

struct PrivacySettingsView: View {
    @Environment(AppModel.self) private var model

    @State private var lockEnabled = LocalSettings.journalLockEnabled
    @State private var confirmJournal = false
    @State private var confirmDownloads = false
    @State private var confirmServer = false
    @State private var serverDeleteDone = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { lockEnabled }, set: { setLock($0) })) {
                    Label("Lock journal with Face ID", systemImage: "faceid")
                        .foregroundStyle(Palette.ink)
                }
                .tint(Palette.accent)
                Button("Delete all journal entries", role: .destructive) {
                    confirmJournal = true
                }
                .disabled(model.journal.entries.isEmpty)
            } header: {
                Text("Journal")
            } footer: {
                Text("Your reflections are stored only on this iPhone, encrypted while it's locked, and are never sent to the server. \(model.journal.entries.count) \(model.journal.entries.count == 1 ? "entry" : "entries").")
            }
            .listRowBackground(Palette.surface)

            Section {
                Button("Remove all downloads", role: .destructive) {
                    confirmDownloads = true
                }
                .disabled(model.downloads.downloadedIDs.isEmpty)
            } header: {
                Text("On this iPhone")
            } footer: {
                Text("Downloaded sessions: \(model.downloads.downloadedIDs.count), using \(ByteCountFormatter.string(fromByteCount: Int64(model.downloads.totalBytes), countStyle: .file)).")
            }
            .listRowBackground(Palette.surface)

            if model.isConnected {
                Section {
                    Button("Delete all my data on the server", role: .destructive) {
                        confirmServer = true
                    }
                    .accessibilityIdentifier("deleteServerDataButton")
                } header: {
                    Text("On your server")
                } footer: {
                    if serverDeleteDone {
                        Text("Done. Your server no longer holds any sessions, scripts, uploads or profile details.")
                    } else {
                        Text("Removes every session, script, audio file, uploaded track, your profile and device registrations from your server. Settings return to their defaults.")
                    }
                }
                .listRowBackground(Palette.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .presentBackground()
        .navigationTitle("Privacy & data")
        .confirmationDialog("Delete all journal entries?", isPresented: $confirmJournal, titleVisibility: .visible) {
            Button("Delete all entries", role: .destructive) { model.journal.deleteAll() }
        } message: {
            Text("This can't be undone.")
        }
        .confirmationDialog("Remove all downloads?", isPresented: $confirmDownloads, titleVisibility: .visible) {
            Button("Remove downloads", role: .destructive) {
                model.stopPlayback()
                model.downloads.deleteAll()
            }
        } message: {
            Text("Sessions stay in your library and can be downloaded again.")
        }
        .alert("Delete everything on your server?", isPresented: $confirmServer) {
            Button("Delete", role: .destructive) {
                Task { serverDeleteDone = await model.deleteAllServerData() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All sessions and audio, uploaded music and your profile will be permanently deleted. Your journal on this iPhone is not affected.")
        }
    }

    private func setLock(_ enabled: Bool) {
        Task {
            // Confirm it's really you before changing the lock either way.
            let ok = await model.unlockJournal()
            if ok {
                LocalSettings.journalLockEnabled = enabled
                lockEnabled = enabled
            }
        }
    }
}

struct ServerSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmDisconnect = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Address", value: LocalSettings.serverURL ?? "—")
                if let version = model.status?.version {
                    LabeledContent("Version", value: version)
                }
            } header: {
                Text("Connection")
            }
            .listRowBackground(Palette.surface)

            if let status = model.status {
                Section {
                    ProviderRow(role: "Script", info: status.providers.script)
                    ProviderRow(role: "Voice", info: status.providers.voice)
                    ProviderRow(role: "Music", info: status.providers.music)
                    HStack {
                        Text("Notifications").foregroundStyle(Palette.ink)
                        Spacer()
                        Text(status.providers.push.configured ? "Push" : "Local reminder")
                            .foregroundStyle(Palette.secondaryInk)
                    }
                } header: {
                    Text("What's making your sessions")
                } footer: {
                    Text("“Demo” means a stand-in is used because a key is missing on the server — nothing is presented as ElevenLabs or Claude unless it really is. \(status.providers.push.detail)")
                }
                .listRowBackground(Palette.surface)

                Section {
                    LabeledContent("This month") {
                        Text(String(format: "$%.2f of $%.2f", status.spend.monthUsd, status.spend.monthLimitUsd))
                    }
                    LabeledContent("Extra sessions today") {
                        Text("\(status.spend.dailyOnDemandCount) of \(status.spend.dailyOnDemandLimit)")
                    }
                    if let error = status.scheduler.lastError {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Last scheduler issue").foregroundStyle(Palette.ink)
                            Text(error).font(Typography.caption).foregroundStyle(Palette.secondaryInk)
                        }
                    }
                } header: {
                    Text("Spending")
                } footer: {
                    Text("Limits are set on your server. When a limit is reached, new sessions pause until the next day or month.")
                }
                .listRowBackground(Palette.surface)
            }

            Section {
                Button("Disconnect", role: .destructive) { confirmDisconnect = true }
            }
            .listRowBackground(Palette.surface)
        }
        .scrollContentBackground(.hidden)
        .presentBackground()
        .navigationTitle("Server")
        .refreshable { await model.refresh() }
        .confirmationDialog("Disconnect from this server?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { model.disconnect() }
        } message: {
            Text("Downloaded sessions and your journal stay on this iPhone.")
        }
    }
}

private struct ProviderRow: View {
    let role: String
    let info: ProviderInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(role).foregroundStyle(Palette.ink)
                Spacer()
                Text(info.name).foregroundStyle(Palette.secondaryInk)
                if info.mode == .demo {
                    DemoBadge()
                } else {
                    Text("Live")
                        .font(.system(.caption2, weight: .semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(Palette.sage)
                }
            }
            if !info.detail.isEmpty {
                Text(info.detail)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.secondaryInk)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
