import SwiftUI

/// A question to sit with, and an optional private note that never leaves the iPhone.
struct ReflectionView: View {
    enum Mode {
        case afterSession
        case fromLibrary
    }

    @Environment(AppModel.self) private var model
    @FocusState private var editorFocused: Bool
    @State private var text = ""

    let session: Session
    var mode: Mode = .afterSession
    var onDone: () -> Void

    private var question: String { session.fallbackReflectionQuestion }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(mode == .afterSession ? "Before you go" : "Reflection")
                        .eyebrowStyle()
                    Text(question)
                        .font(Typography.reflection)
                        .foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("reflectionQuestion")
                }
                .padding(.top, mode == .afterSession ? 48 : 16)

                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Write if you'd like — this stays on your iPhone.")
                            .font(Typography.body)
                            .foregroundStyle(Palette.secondaryInk.opacity(0.8))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $text)
                        .font(Typography.body)
                        .foregroundStyle(Palette.ink)
                        .scrollContentBackground(.hidden)
                        .focused($editorFocused)
                        .frame(minHeight: 180)
                        .accessibilityIdentifier("journalEditor")
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Palette.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Palette.hairline, lineWidth: 1)
                )

                Label("Private. Stored only on this iPhone and never sent anywhere.", systemImage: "lock")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.secondaryInk)

                VStack(spacing: 6) {
                    Button("Save") {
                        model.journal.add(sessionId: session.id,
                                          sessionTitle: session.displayTitle,
                                          question: question,
                                          text: text)
                        onDone()
                    }
                    .buttonStyle(SoftCapsuleButtonStyle())
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
                    .accessibilityIdentifier("saveReflectionButton")

                    Button(mode == .afterSession ? "Just sit with it" : "Close") {
                        onDone()
                    }
                    .buttonStyle(QuietButtonStyle())
                    .accessibilityIdentifier("skipReflectionButton")
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
        .presentBackground()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reflectionView")
    }
}
