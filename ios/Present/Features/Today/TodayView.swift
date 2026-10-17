import SwiftUI

struct TodayView: View {
    @Environment(AppModel.self) private var model
    @State private var showingNewSession = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    header
                        .padding(.top, 12)

                    if model.isOffline {
                        OfflineNote()
                            .padding(.top, 16)
                    }

                    content
                        .padding(.top, 32)

                    footer
                        .padding(.top, 28)
                        .padding(.bottom, 40)
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .refreshable { await model.refresh() }
            .presentBackground()
            .toolbar(.hidden, for: .navigationBar)
            .withMiniPlayer()
            .sheet(isPresented: $showingNewSession) {
                NewSessionSheet()
                    .environment(model)
                    .presentationDetents([.medium, .large])
                    .presentationBackground(Palette.background)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(TimeFormat.longDate(Date()))
                .eyebrowStyle()
            Text(greeting)
                .font(Typography.title)
                .foregroundStyle(Palette.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let base: String
        switch hour {
        case 4..<12: base = "Good morning"
        case 12..<17: base = "Good afternoon"
        case 17..<22: base = "Good evening"
        default: base = "Hello"
        }
        let name = model.settings?.profile.name.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? base : "\(base), \(name)"
    }

    // MARK: Main content

    @ViewBuilder
    private var content: some View {
        if let session = model.displayedSession {
            switch session.status {
            case .ready:
                ReadySessionView(session: session)
            case .queued, .generating:
                GeneratingView(session: session)
            case .failed:
                FailedView(session: session)
            }
        } else if !model.hasLoadedOnce && model.isConnected {
            ProgressView()
                .tint(Palette.secondaryInk)
                .frame(height: 320)
        } else {
            NothingYetView()
        }
    }

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: 4) {
            if model.isDemo {
                Text("You're exploring a demo session that lives on this iPhone. Connect your Present server in Settings for a fresh session each morning.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.secondaryInk)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                Button("Connect your server") {
                    model.selectedTab = .settings
                }
                .buttonStyle(QuietButtonStyle())
            } else if model.isConnected {
                Button("A different session…") {
                    showingNewSession = true
                }
                .buttonStyle(QuietButtonStyle())
                .accessibilityIdentifier("newSessionButton")
            }
            if let message = model.errorMessage {
                Text(message)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.secondaryInk)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
            }
        }
    }
}

// MARK: - States

private struct ReadySessionView: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    ThemeLine(theme: session.theme, minutes: session.durationMinutes)
                    if session.demo { DemoBadge() }
                }
                Text(session.displayTitle)
                    .font(Typography.display)
                    .foregroundStyle(Palette.ink)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("todayTitle")
                if let summary = session.summary {
                    Text(summary)
                        .font(Typography.body)
                        .foregroundStyle(Palette.secondaryInk)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .padding(.horizontal, 8)
                }
            }

            PrimaryPlayButton(isPreparing: model.preparingSessionID == session.id) {
                Task { await model.play(session) }
            }
            .accessibilityIdentifier("playButton")
            .padding(.top, 8)

            availability
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var availability: some View {
        if model.isAvailableOffline(session) {
            Label("Available offline", systemImage: "arrow.down.circle")
                .font(Typography.caption)
                .foregroundStyle(Palette.sage)
        } else if model.downloads.isDownloading(session.id) {
            Label("Saving for offline…", systemImage: "arrow.down.circle.dotted")
                .font(Typography.caption)
                .foregroundStyle(Palette.secondaryInk)
        }
    }
}

private struct GeneratingView: View {
    let session: Session

    var body: some View {
        VStack(spacing: 22) {
            BreathingCircle(color: Palette.accentSoft)
                .frame(width: 160, height: 160)
                .padding(.vertical, 12)
            VStack(spacing: 8) {
                Text("Preparing your session")
                    .font(Typography.title2)
                    .foregroundStyle(Palette.ink)
                Text("\(session.theme.displayName) · \(session.durationMinutes) min")
                    .eyebrowStyle()
                Text(session.statusDetail ?? "Writing, recording and mixing. This takes a minute or two.")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.secondaryInk)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
                    .animation(Motion.gentle, value: session.statusDetail)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("generatingView")
    }
}

private struct FailedView: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "cloud.drizzle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Palette.secondaryInk)
            Text("Today's session didn't come together")
                .font(Typography.title2)
                .foregroundStyle(Palette.ink)
                .multilineTextAlignment(.center)
            Text(session.statusDetail ?? "Something interrupted it along the way.")
                .font(Typography.callout)
                .foregroundStyle(Palette.secondaryInk)
                .multilineTextAlignment(.center)
            Button {
                Task { await model.createSession(theme: session.theme, durationMinutes: session.durationMinutes) }
            } label: {
                if model.isCreating {
                    ProgressView().tint(Palette.onAccent)
                } else {
                    Text("Try again")
                }
            }
            .buttonStyle(SoftCapsuleButtonStyle())
            .disabled(model.isCreating)
            .padding(.horizontal, 40)
            .accessibilityIdentifier("retryButton")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

private struct NothingYetView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 20) {
            BreathingCircle(color: Palette.accentSoft.opacity(0.7), active: false)
                .frame(width: 140, height: 140)
            if model.isConnected {
                Text(nextLine)
                    .font(Typography.title3)
                    .foregroundStyle(Palette.ink)
                    .multilineTextAlignment(.center)
                Button {
                    Task { await model.createSession(theme: nil, durationMinutes: nil) }
                } label: {
                    if model.isCreating {
                        ProgressView().tint(Palette.onAccent)
                    } else {
                        Text("Create a session now")
                    }
                }
                .buttonStyle(SoftCapsuleButtonStyle())
                .disabled(model.isCreating)
                .padding(.horizontal, 40)
                .accessibilityIdentifier("createNowButton")
            } else {
                Text("The demo session isn't available in this build.")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.secondaryInk)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var nextLine: String {
        if let next = model.nextDailyAt {
            let day = Calendar.current.isDateInToday(next) ? "today" : "tomorrow"
            return "Your next session will be ready \(day) at \(TimeFormat.time(next))."
        }
        if model.settings?.dailyEnabled == false {
            return "Daily sessions are paused. You can still make one whenever you like."
        }
        return "Nothing here yet. Would you like a session now?"
    }
}

struct OfflineNote: View {
    var body: some View {
        Label("Offline — downloaded sessions still play", systemImage: "wifi.slash")
            .font(Typography.caption)
            .foregroundStyle(Palette.secondaryInk)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Palette.surface))
            .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
    }
}
