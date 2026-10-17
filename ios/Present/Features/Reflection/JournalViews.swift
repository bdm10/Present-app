import SwiftUI

/// One journal entry, used in session detail and the journal list.
struct JournalEntryCard: View {
    let entry: JournalEntry
    var showsSession: Bool = true
    var onEdit: () -> Void
    var onDelete: () -> Void

    @State private var confirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .eyebrowStyle()
                Spacer()
                Menu {
                    Button("Edit", systemImage: "pencil", action: onEdit)
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        confirmingDelete = true
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(Palette.secondaryInk)
                        .frame(width: 32, height: 24)
                }
                .accessibilityLabel("Entry options")
            }
            if showsSession {
                Text(entry.sessionTitle)
                    .font(Typography.callout)
                    .foregroundStyle(Palette.secondaryInk)
                Text(entry.question)
                    .font(Typography.callout)
                    .italic()
                    .foregroundStyle(Palette.secondaryInk)
            }
            Text(entry.text)
                .font(Typography.body)
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("journalEntryText")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .confirmationDialog("Delete this entry?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete entry", role: .destructive, action: onDelete)
        }
    }
}

/// Edit an existing entry.
struct JournalEditSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let entry: JournalEntry
    @State private var text = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(entry.question)
                    .font(Typography.title3)
                    .italic()
                    .foregroundStyle(Palette.ink)
                TextEditor(text: $text)
                    .font(Typography.body)
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.surface))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
            }
            .padding(24)
            .presentBackground()
            .navigationTitle("Edit reflection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.journal.update(entry.id, text: text)
                        dismiss()
                    }
                }
            }
            .onAppear { text = entry.text }
        }
    }
}

/// Every reflection, newest first. Locked behind Face ID when enabled.
struct JournalListView: View {
    @Environment(AppModel.self) private var model
    @State private var editingEntry: JournalEntry?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if model.journalNeedsUnlock {
                    VStack(spacing: 14) {
                        Image(systemName: "lock")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(Palette.secondaryInk)
                        Text("Your journal is locked.")
                            .font(Typography.title3)
                            .foregroundStyle(Palette.ink)
                        Button("Unlock") {
                            Task { _ = await model.unlockJournal() }
                        }
                        .buttonStyle(SoftCapsuleButtonStyle())
                        .padding(.horizontal, 60)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else if model.journal.entries.isEmpty {
                    Text("Reflections you write after a session will appear here. They're stored only on this iPhone.")
                        .font(Typography.callout)
                        .foregroundStyle(Palette.secondaryInk)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                } else {
                    ForEach(model.journal.entries) { entry in
                        JournalEntryCard(entry: entry) {
                            editingEntry = entry
                        } onDelete: {
                            model.journal.delete(entry.id)
                        }
                    }
                }
            }
            .padding(20)
        }
        .presentBackground()
        .navigationTitle("Journal")
        .sheet(item: $editingEntry) { entry in
            JournalEditSheet(entry: entry)
                .environment(model)
                .presentationBackground(Palette.background)
        }
    }
}
