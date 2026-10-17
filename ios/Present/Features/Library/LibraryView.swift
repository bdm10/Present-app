import SwiftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var filter: Filter = .all
    @State private var pendingDelete: Session?

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case favourites = "Favourites"
        var id: String { rawValue }
    }

    private var visibleSessions: [Session] {
        let all = model.librarySessions
        switch filter {
        case .all: return all
        case .favourites: return all.filter(\.favorite)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Show", selection: $filter) {
                        ForEach(Filter.allCases) { f in
                            Text(f.rawValue).tag(f)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("libraryFilter")
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                }

                if model.isOffline {
                    Section {
                        OfflineNote()
                            .frame(maxWidth: .infinity)
                            .listRowBackground(Color.clear)
                    }
                }

                if visibleSessions.isEmpty {
                    Section {
                        EmptyLibraryNote(filter: filter)
                            .listRowBackground(Color.clear)
                    }
                } else {
                    Section {
                        ForEach(visibleSessions) { session in
                            NavigationLink(value: session.id) {
                                SessionRow(session: session)
                            }
                            .listRowBackground(Palette.surface)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if !model.isBundledDemo(session) {
                                    Button(role: .destructive) {
                                        pendingDelete = session
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .presentBackground()
            .navigationTitle("Library")
            .navigationDestination(for: String.self) { id in
                SessionDetailView(sessionID: id)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        JournalListView()
                    } label: {
                        Image(systemName: "book.closed")
                            .foregroundStyle(Palette.ink)
                    }
                    .accessibilityLabel("Journal")
                    .accessibilityIdentifier("journalButton")
                }
            }
            .refreshable { await model.refresh() }
            .withMiniPlayer()
            .confirmationDialog("Delete this session?",
                                isPresented: Binding(get: { pendingDelete != nil },
                                                     set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible,
                                presenting: pendingDelete) { session in
                Button("Delete session", role: .destructive) {
                    Task { await model.deleteSession(session) }
                }
            } message: { _ in
                Text("Its audio is removed from your server and this iPhone. Journal entries stay.")
            }
        }
    }
}

struct SessionRow: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(dateLine)
                        .eyebrowStyle()
                    if session.demo { DemoBadge() }
                }
                Text(session.displayTitle)
                    .font(Typography.title3)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Image(systemName: session.theme.symbol)
                    Text("\(session.theme.displayName) · \(session.durationMinutes) min")
                    statusAccessory
                }
                .font(Typography.caption)
                .foregroundStyle(Palette.secondaryInk)
            }
            Spacer(minLength: 8)
            Button {
                Task { await model.toggleFavorite(session) }
            } label: {
                Image(systemName: session.favorite ? "heart.fill" : "heart")
                    .font(.system(size: 18))
                    .foregroundStyle(session.favorite ? Palette.accent : Palette.secondaryInk)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(session.favorite ? "Remove from favourites" : "Add to favourites")
            .accessibilityIdentifier("favoriteButton")
        }
        .padding(.vertical, 6)
    }

    private var dateLine: String {
        guard let day = session.day else { return session.localDate }
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return TimeFormat.shortDate(day)
    }

    @ViewBuilder
    private var statusAccessory: some View {
        switch session.status {
        case .ready:
            if model.isAvailableOffline(session) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(Palette.sage)
                    .accessibilityLabel("Downloaded")
            }
        case .queued, .generating:
            Text("· preparing")
        case .failed:
            Text("· didn't finish")
        }
    }
}

private struct EmptyLibraryNote: View {
    let filter: LibraryView.Filter

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: filter == .favourites ? "heart" : "books.vertical")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Palette.secondaryInk)
            Text(filter == .favourites
                 ? "Sessions you love will gather here."
                 : "Your sessions will collect here, one quiet morning at a time.")
                .font(Typography.callout)
                .foregroundStyle(Palette.secondaryInk)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}
