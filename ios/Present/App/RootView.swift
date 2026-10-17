import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.connection == .disconnected {
                WelcomeView()
                    .transition(.opacity)
            } else {
                MainTabs()
                    .transition(.opacity)
            }
        }
        .animation(Motion.gentle, value: model.connection == .disconnected)
        .fullScreenCover(isPresented: $model.isPlayerPresented) {
            PlayerView()
                .environment(model)
        }
    }
}

private struct MainTabs: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            TodayView()
                .tabItem { Label("Today", systemImage: "sun.horizon") }
                .tag(AppTab.today)
            LibraryView()
                .tabItem { Label("Library", systemImage: "books.vertical") }
                .tag(AppTab.library)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
                .tag(AppTab.settings)
        }
    }
}

/// A slim bar above the tab bar that returns to the player.
struct MiniPlayerBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let session = model.player.session, !model.isPlayerPresented, !model.player.didFinish {
            HStack(spacing: 14) {
                BreathingCircle(color: Palette.accentSoft, active: model.player.isPlaying)
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayTitle)
                        .font(.system(.subheadline, design: .serif))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Text(TimeFormat.remaining(model.player.remaining))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Palette.secondaryInk)
                }
                Spacer()
                Button {
                    model.player.togglePlayPause()
                } label: {
                    Image(systemName: model.player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .foregroundStyle(Palette.ink)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(model.player.isPlaying ? "Pause" : "Play")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Palette.surface)
                    .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: 1)
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .contentShape(Rectangle())
            .onTapGesture { model.isPlayerPresented = true }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("miniPlayer")
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

extension View {
    /// Shows the mini player above the tab bar when a session is loaded.
    func withMiniPlayer() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            MiniPlayerBar()
        }
    }
}
