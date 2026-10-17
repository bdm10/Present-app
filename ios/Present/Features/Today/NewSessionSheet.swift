import SwiftUI

/// "A different session…" — choose a length and a theme, then create.
struct NewSessionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var duration = 10
    @State private var theme: Theme = .presence
    @State private var didLoadDefaults = false

    private let durations = [5, 10, 15, 20]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text("Make a session for right now. It takes a minute or two to prepare.")
                        .font(Typography.callout)
                        .foregroundStyle(Palette.secondaryInk)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Length").eyebrowStyle()
                        PillPicker(options: durations, selection: $duration,
                                   label: { "\($0) min" },
                                   identifier: { "durationPill_\($0)" })
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Theme").eyebrowStyle()
                        PillPicker(options: Theme.allCases, selection: $theme,
                                   label: { $0.displayName },
                                   identifier: { "themePill_\($0.rawValue)" })
                    }

                    Button {
                        Task {
                            let created = await model.createSession(theme: theme, durationMinutes: duration)
                            if created != nil { dismiss() }
                        }
                    } label: {
                        if model.isCreating {
                            ProgressView().tint(Palette.onAccent)
                        } else {
                            Text("Create")
                        }
                    }
                    .buttonStyle(SoftCapsuleButtonStyle())
                    .disabled(model.isCreating)
                    .accessibilityIdentifier("createSessionButton")

                    if let message = model.errorMessage {
                        Text(message)
                            .font(Typography.caption)
                            .foregroundStyle(Palette.secondaryInk)
                    }
                }
                .padding(24)
            }
            .presentBackground()
            .navigationTitle("A different session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onAppear {
            guard !didLoadDefaults else { return }
            didLoadDefaults = true
            if let settings = model.settings {
                duration = settings.defaultDurationMinutes
                theme = settings.themes.first ?? .presence
            }
        }
    }
}
