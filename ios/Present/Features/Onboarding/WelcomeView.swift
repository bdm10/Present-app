import SwiftUI

struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer()
                BreathingCircle(color: Palette.accentSoft)
                    .frame(width: 180, height: 180)
                    .overlay(Circle().fill(Palette.accent.opacity(0.2)).frame(width: 70, height: 70))
                Text("Present")
                    .font(.system(size: 44, weight: .regular, design: .serif))
                    .foregroundStyle(Palette.ink)
                    .padding(.top, 36)
                Text("A few quiet minutes, made fresh each morning.")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.secondaryInk)
                    .multilineTextAlignment(.center)
                    .padding(.top, 10)
                    .padding(.horizontal, 40)
                Spacer()
                VStack(spacing: 10) {
                    NavigationLink {
                        ConnectView()
                    } label: {
                        Text("Connect to your Present server")
                    }
                    .buttonStyle(SoftCapsuleButtonStyle())
                    .accessibilityIdentifier("connectButton")

                    Button("Explore the demo") {
                        model.enterDemo()
                    }
                    .buttonStyle(SoftCapsuleButtonStyle(filled: false))
                    .accessibilityIdentifier("exploreDemoButton")

                    Text("The demo plays a sample session stored on this iPhone. No account needed.")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.secondaryInk)
                        .multilineTextAlignment(.center)
                        .padding(.top, 6)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 32)
            }
            .presentBackground()
        }
    }
}

struct ConnectView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var address = LocalSettings.serverURL ?? ""
    @State private var token = ""
    @State private var connecting = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("https://present-yourname.fly.dev", text: $address)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("serverURLField")
            } header: {
                Text("Server address")
            }
            Section {
                SecureField("Access token", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("tokenField")
            } header: {
                Text("Access token")
            } footer: {
                Text("Printed by your server the first time it starts (APP_TOKEN). It's stored in the iPhone Keychain.")
            }
            Section {
                Button {
                    Task { await connect() }
                } label: {
                    HStack {
                        Text("Connect")
                        Spacer()
                        if connecting { ProgressView() }
                    }
                }
                .disabled(connecting || address.isEmpty || token.isEmpty)
                .accessibilityIdentifier("connectSubmitButton")
            } footer: {
                if let error {
                    Text(error).foregroundStyle(Palette.accent)
                }
            }
        }
        .listRowBackground(Palette.surface)
        .scrollContentBackground(.hidden)
        .presentBackground()
        .navigationTitle("Connect")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func connect() async {
        connecting = true
        error = nil
        defer { connecting = false }
        do {
            try await model.connect(urlString: address, token: token)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
