import SwiftUI

/// Full-screen listening view. When the session ends it turns into the reflection.
struct PlayerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.player.didFinish, let session = model.player.session {
                ReflectionView(session: session, mode: .afterSession) {
                    model.endSession()
                }
                .transition(.opacity)
            } else {
                PlayerContent()
                    .transition(.opacity)
            }
        }
        .animation(Motion.gentle, value: model.player.didFinish)
        .presentBackground()
    }
}

private struct PlayerContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false

    private var player: SessionPlayer { model.player }

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 20)
                .padding(.top, 8)

            Spacer(minLength: 12)

            BreathingCircle(color: Palette.accentSoft, active: player.isPlaying)
                .frame(width: 220, height: 220)
                .overlay(
                    Circle()
                        .fill(Palette.accent.opacity(0.18))
                        .frame(width: 90, height: 90)
                )

            Spacer(minLength: 12)

            VStack(spacing: 8) {
                if let session = player.session {
                    HStack(spacing: 8) {
                        ThemeLine(theme: session.theme, minutes: session.durationMinutes)
                        if session.demo { DemoBadge() }
                    }
                    Text(session.displayTitle)
                        .font(Typography.title)
                        .foregroundStyle(Palette.ink)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                }
            }
            .padding(.horizontal, 28)

            scrubber
                .padding(.horizontal, 28)
                .padding(.top, 28)

            transport
                .padding(.top, 20)

            volumes
                .padding(.horizontal, 28)
                .padding(.top, 28)
                .padding(.bottom, 24)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("playerView")
        .onAppear { scrubValue = player.currentTime }
        .onChange(of: player.currentTime) { _, newValue in
            if !isScrubbing { scrubValue = newValue }
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Palette.secondaryInk)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Minimise player")
            .accessibilityIdentifier("closePlayerButton")
            Spacer()
            Text("Now playing")
                .eyebrowStyle()
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
    }

    private var scrubber: some View {
        VStack(spacing: 6) {
            Slider(value: $scrubValue, in: 0...max(player.duration, 1), onEditingChanged: { editing in
                isScrubbing = editing
                if !editing { player.seek(to: scrubValue) }
            })
            .tint(Palette.accent)
            .accessibilityLabel("Position")
            .accessibilityValue(TimeFormat.clock(scrubValue))

            HStack {
                Text(TimeFormat.clock(isScrubbing ? scrubValue : player.currentTime))
                    .accessibilityIdentifier("elapsedLabel")
                Spacer()
                Text(TimeFormat.remaining(max(0, player.duration - (isScrubbing ? scrubValue : player.currentTime))))
                    .accessibilityIdentifier("remainingLabel")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(Palette.secondaryInk)
        }
    }

    private var transport: some View {
        HStack(spacing: 44) {
            Button {
                player.skip(by: -15)
            } label: {
                Image(systemName: "gobackward.15")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 52, height: 52)
            }
            .accessibilityLabel("Back 15 seconds")

            Button {
                player.togglePlayPause()
            } label: {
                ZStack {
                    Circle()
                        .fill(Palette.accent)
                        .frame(width: 76, height: 76)
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(Palette.onAccent)
                        .offset(x: player.isPlaying ? 0 : 2)
                }
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            .accessibilityIdentifier("playPauseButton")

            Button {
                player.skip(by: 15)
            } label: {
                Image(systemName: "goforward.15")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 52, height: 52)
            }
            .accessibilityLabel("Forward 15 seconds")
        }
    }

    private var volumes: some View {
        VStack(spacing: 14) {
            VolumeRow(title: "Voice", symbol: "waveform",
                      value: Binding(get: { Double(player.voiceVolume) },
                                     set: { player.setVoiceVolume(Float($0)) }))
                .accessibilityIdentifier("voiceVolumeSlider")
            VolumeRow(title: "Music", symbol: "music.note",
                      value: Binding(get: { Double(player.musicVolume) },
                                     set: { player.setMusicVolume(Float($0)) }))
                .accessibilityIdentifier("musicVolumeSlider")
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
    }
}

private struct VolumeRow: View {
    let title: String
    let symbol: String
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(Palette.secondaryInk)
                .frame(width: 20)
            Text(title)
                .font(Typography.callout)
                .foregroundStyle(Palette.ink)
                .frame(width: 52, alignment: .leading)
            Slider(value: $value, in: 0...1)
                .tint(Palette.sage)
                .accessibilityLabel("\(title) volume")
        }
    }
}
