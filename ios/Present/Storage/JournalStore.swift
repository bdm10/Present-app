import Foundation
import Observation

struct JournalEntry: Codable, Identifiable, Hashable {
    var id: UUID
    var sessionId: String
    var sessionTitle: String
    var question: String
    var text: String
    var createdAt: Date
    var updatedAt: Date
}

/// Private reflections. Stored only on this iPhone, in a file with complete data
/// protection (unreadable while the device is locked). Never sent to the server.
@MainActor
@Observable
final class JournalStore {
    private(set) var entries: [JournalEntry] = []
    let fileURL: URL

    @ObservationIgnored private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    @ObservationIgnored private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(directory: URL? = nil) {
        let dir: URL
        if let directory {
            dir = directory
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            dir = support.appendingPathComponent("Present/Journal", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("journal.json")
        reload()
    }

    func reload() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode([JournalEntry].self, from: data) else {
            entries = []
            return
        }
        entries = decoded.sorted { $0.createdAt > $1.createdAt }
    }

    func entries(for sessionId: String) -> [JournalEntry] {
        entries.filter { $0.sessionId == sessionId }
    }

    @discardableResult
    func add(sessionId: String, sessionTitle: String, question: String, text: String) -> JournalEntry? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let now = Date()
        let entry = JournalEntry(id: UUID(), sessionId: sessionId, sessionTitle: sessionTitle,
                                 question: question, text: trimmed, createdAt: now, updatedAt: now)
        entries.insert(entry, at: 0)
        persist()
        return entry
    }

    func update(_ id: UUID, text: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            delete(id)
            return
        }
        entries[index].text = trimmed
        entries[index].updatedAt = Date()
        persist()
    }

    func delete(_ id: UUID) {
        entries.removeAll { $0.id == id }
        persist()
    }

    func deleteAll() {
        entries.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func persist() {
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }
}
