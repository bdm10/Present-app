import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            Form {
                if model.isConnected {
                    ConnectedSettingsSections()
                } else {
                    DemoSettingsSections()
                }
            }
            .scrollContentBackground(.hidden)
            .presentBackground()
            .navigationTitle("Settings")
            .task {
                if model.isConnected {
                    await model.refreshVoicesAndMusic()
                }
            }
            .refreshable {
                await model.refresh()
                await model.refreshVoicesAndMusic()
            }
        }
    }
}

// MARK: - Connected

private struct ConnectedSettingsSections: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let settings = model.settings {
            DailySection(settings: settings)
            ListeningSection(settings: settings)
            RemindersSection(settings: settings)
            Section {
                NavigationLink {
                    ProfileView()
                } label: {
                    SettingsRowLabel(title: "About you", symbol: "person",
                                     detail: settings.profile.name.isEmpty ? "Optional" : settings.profile.name)
                }
            } footer: {
                Text("A few words about your life help each session feel like it was written for you.")
            }
        } else {
            Section {
                HStack {
                    ProgressView()
                    Text(model.isOffline ? "Offline — settings will load when you're connected." : "Loading…")
                        .foregroundStyle(Palette.secondaryInk)
                }
            }
        }

        Section {
            NavigationLink {
                PrivacySettingsView()
            } label: {
                SettingsRowLabel(title: "Privacy & data", symbol: "lock", detail: nil)
            }
            NavigationLink {
                ServerSettingsView()
            } label: {
                SettingsRowLabel(title: "Server", symbol: "server.rack", detail: modeSummary)
            }
        }
        .listRowBackground(Palette.surface)
    }

    private var modeSummary: String? {
        guard let status = model.status else { return nil }
        let p = status.providers
        let anyDemo = [p.script.mode, p.voice.mode, p.music.mode].contains(.demo)
        return anyDemo ? "Demo mode" : "Live"
    }
}

private struct DailySection: View {
    @Environment(AppModel.self) private var model
    let settings: UserSettings

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { settings.dailyEnabled },
                                 set: { value in Task { await model.updateSettings { $0.dailyEnabled = value } } })) {
                SettingsRowLabel(title: "Daily session", symbol: "sunrise", detail: nil)
            }
            .tint(Palette.accent)
            .accessibilityIdentifier("dailyToggle")

            if settings.dailyEnabled {
                DatePicker(selection: timeBinding, displayedComponents: .hourAndMinute) {
                    SettingsRowLabel(title: "Ready by", symbol: "clock", detail: nil)
                }
                .accessibilityIdentifier("dailyTimePicker")

                VStack(alignment: .leading, spacing: 10) {
                    SettingsRowLabel(title: "Length", symbol: "hourglass", detail: nil)
                    PillPicker(options: [5, 10, 15, 20],
                               selection: Binding(get: { settings.defaultDurationMinutes },
                                                  set: { value in Task { await model.updateSettings { $0.defaultDurationMinutes = value } } }),
                               label: { "\($0) min" },
                               identifier: { "settingsDuration_\($0)" })
                }
                .padding(.vertical, 6)

                NavigationLink {
                    ThemesView()
                } label: {
                    SettingsRowLabel(title: "Themes", symbol: "leaf",
                                     detail: settings.themes.count == 1 ? settings.themes[0].displayName : "\(settings.themes.count) themes")
                }
            }
        } header: {
            Text("Each morning")
        } footer: {
            Text("A new session is written and recorded shortly before this time, in \(friendlyZone(settings.timeZone)).")
        }
        .listRowBackground(Palette.surface)
    }

    private var timeBinding: Binding<Date> {
        Binding(get: {
            let c = settings.dailyTimeComponents
            return Calendar.current.date(bySettingHour: c.hour ?? 7, minute: c.minute ?? 0, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            let value = UserSettings.formatTime(hour: c.hour ?? 7, minute: c.minute ?? 0)
            Task { await model.updateSettings { $0.dailyTime = value } }
        })
    }

    private func friendlyZone(_ identifier: String) -> String {
        TimeZone(identifier: identifier)?.localizedName(for: .generic, locale: .current) ?? identifier
    }
}

private struct ListeningSection: View {
    @Environment(AppModel.self) private var model
    let settings: UserSettings

    var body: some View {
        Section {
            NavigationLink {
                VoiceSettingsView()
            } label: {
                SettingsRowLabel(title: "Voice", symbol: "waveform", detail: currentVoiceName)
            }
            .accessibilityIdentifier("voiceSettingsLink")
            NavigationLink {
                MusicSettingsView()
            } label: {
                SettingsRowLabel(title: "Music", symbol: "music.note", detail: currentMusicName)
            }
            .accessibilityIdentifier("musicSettingsLink")
        } header: {
            Text("Listening")
        } footer: {
            Text("Voice and music volume can be adjusted separately while you listen.")
        }
        .listRowBackground(Palette.surface)
    }

    private var currentVoiceName: String? {
        model.voices.first { $0.id == settings.voiceId }?.name
    }

    private var currentMusicName: String? {
        if settings.musicTrackId == "auto" { return "Choose for me" }
        return model.tracks.first { $0.id == settings.musicTrackId }?.title
    }
}

private struct RemindersSection: View {
    @Environment(AppModel.self) private var model
    let settings: UserSettings
    @State private var permissionDenied = false

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { settings.notifyWhenReady }, set: { value in
                Task {
                    if value {
                        let granted = await model.enableNotifications()
                        permissionDenied = !granted
                    }
                    await model.updateSettings { $0.notifyWhenReady = value }
                }
            })) {
                SettingsRowLabel(title: "Let me know when it's ready", symbol: "bell", detail: nil)
            }
            .tint(Palette.accent)
            .accessibilityIdentifier("notifyToggle")
        } header: {
            Text("Reminders")
        } footer: {
            if permissionDenied {
                Text("Notifications are turned off for Present. You can allow them in the iPhone Settings app.")
            } else if model.usesLocalReminder {
                Text("Your server can't send push notifications to this iPhone yet, so Present sets a gentle reminder on the phone itself at your chosen time.")
            } else {
                Text("Your server sends a notification as soon as the session is ready.")
            }
        }
        .listRowBackground(Palette.surface)
    }
}

// MARK: - Demo

private struct DemoSettingsSections: View {
    @Environment(AppModel.self) private var model
    @State private var showingConnect = false

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Exploring the demo")
                        .font(Typography.title3)
                    DemoBadge()
                }
                Text("The demo session is bundled with the app and plays offline. Its voice is an offline open-source voice, not ElevenLabs. Connect your Present server for daily, personalised sessions.")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.secondaryInk)
            }
            .padding(.vertical, 6)
            Button("Connect your server") { showingConnect = true }
                .accessibilityIdentifier("connectServerButton")
        }
        .listRowBackground(Palette.surface)
        .sheet(isPresented: $showingConnect) {
            NavigationStack {
                ConnectView()
                    .environment(model)
            }
        }

        Section {
            NavigationLink {
                PrivacySettingsView()
            } label: {
                SettingsRowLabel(title: "Privacy & data", symbol: "lock", detail: nil)
            }
            Button("Leave the demo", role: .destructive) {
                model.disconnect()
            }
        }
        .listRowBackground(Palette.surface)
    }
}

// MARK: - Shared pieces

struct SettingsRowLabel: View {
    let title: String
    let symbol: String
    let detail: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(Palette.accent)
                .frame(width: 24)
            Text(title)
                .foregroundStyle(Palette.ink)
            Spacer(minLength: 8)
            if let detail {
                Text(detail)
                    .foregroundStyle(Palette.secondaryInk)
                    .lineLimit(1)
            }
        }
    }
}

struct ThemesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            if let settings = model.settings {
                Section {
                    ForEach(Theme.allCases) { theme in
                        let isOn = settings.themes.contains(theme)
                        Button {
                            toggle(theme, currentlyOn: isOn, settings: settings)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: theme.symbol)
                                    .foregroundStyle(Palette.accent)
                                    .frame(width: 24)
                                Text(theme.displayName)
                                    .foregroundStyle(Palette.ink)
                                Spacer()
                                if isOn {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Palette.accent)
                                }
                            }
                        }
                        .accessibilityIdentifier("themeToggle_\(theme.rawValue)")
                        .accessibilityAddTraits(isOn ? .isSelected : [])
                    }
                } footer: {
                    Text("Daily sessions gently rotate through the themes you choose.")
                }
                .listRowBackground(Palette.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .presentBackground()
        .navigationTitle("Themes")
    }

    private func toggle(_ theme: Theme, currentlyOn: Bool, settings: UserSettings) {
        var themes = settings.themes
        if currentlyOn {
            guard themes.count > 1 else { return }   // keep at least one
            themes.removeAll { $0 == theme }
        } else {
            themes.append(theme)
        }
        let ordered = Theme.allCases.filter { themes.contains($0) }
        Task { await model.updateSettings { $0.themes = ordered } }
    }
}

struct ProfileView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var lovedOnes = ""
    @State private var context = ""
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                TextField("Your first name", text: $name)
                    .textContentType(.givenName)
            } header: {
                Text("Name")
            }
            Section {
                TextField("e.g. my partner Sam and our two kids", text: $lovedOnes, axis: .vertical)
                    .lineLimit(2...4)
            } header: {
                Text("The people you want to be present for")
            }
            Section {
                TextField("e.g. I lead a busy team and find it hard to switch off in the evenings", text: $context, axis: .vertical)
                    .lineLimit(3...6)
            } header: {
                Text("What's going on for you")
            } footer: {
                Text("Stored on your server and shared only with the script writer (Claude) to personalise sessions. Delete it any time.")
            }
        }
        .listRowBackground(Palette.surface)
        .scrollContentBackground(.hidden)
        .presentBackground()
        .navigationTitle("About you")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    let profile = UserProfile(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                              lovedOnes: lovedOnes.trimmingCharacters(in: .whitespacesAndNewlines),
                                              context: context.trimmingCharacters(in: .whitespacesAndNewlines))
                    Task {
                        await model.updateSettings { $0.profile = profile }
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            guard !loaded, let profile = model.settings?.profile else { return }
            loaded = true
            name = profile.name
            lovedOnes = profile.lovedOnes
            context = profile.context
        }
    }
}
