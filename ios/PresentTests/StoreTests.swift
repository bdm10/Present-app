import XCTest
@testable import Present

final class StoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("PresentTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeSession(id: String, voiceBytes: Int, musicBytes: Int) -> Session {
        Session(id: id, kind: .onDemand, localDate: "2026-10-17", createdAt: "2026-10-17T07:00:00Z",
                status: .ready, statusDetail: nil, theme: .gratitude, durationMinutes: 5,
                title: "Small Kindnesses", summary: nil, reflectionQuestion: "Who helped you this week?",
                durationSeconds: 300, favorite: false, demo: true, providers: nil, voiceName: nil,
                musicTitle: nil,
                audio: SessionAudio(voiceUrl: "/v", musicUrl: "/m", voiceBytes: voiceBytes, musicBytes: musicBytes),
                transcript: nil)
    }

    private func writeTemp(_ bytes: Int) throws -> URL {
        let url = tempDir.appendingPathComponent(UUID().uuidString)
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    // MARK: DownloadStore

    @MainActor
    func testDownloadStoreInstallQueryAndDelete() throws {
        let store = DownloadStore(baseDirectory: tempDir.appendingPathComponent("Present"))
        let session = makeSession(id: "ses_1", voiceBytes: 1200, musicBytes: 3400)
        XCTAssertFalse(store.isDownloaded(session))

        try store.install(session, voiceFile: try writeTemp(1200), musicFile: try writeTemp(3400))

        XCTAssertTrue(store.isDownloaded(session))
        XCTAssertTrue(store.downloadedIDs.contains("ses_1"))
        XCTAssertEqual(store.voiceURL(for: "ses_1").lastPathComponent, "voice.m4a")
        XCTAssertTrue(store.voiceURL(for: "ses_1").path.contains("/Present/Sessions/ses_1/"))
        XCTAssertEqual(store.downloadedSessions().map(\.id), ["ses_1"])
        XCTAssertGreaterThan(store.totalBytes, 4000)

        // Protection must allow background playback while locked (where the platform reports it).
        let attributes = try FileManager.default.attributesOfItem(atPath: store.voiceURL(for: "ses_1").path)
        if let protection = attributes[.protectionKey] as? FileProtectionType {
            XCTAssertEqual(protection, .completeUntilFirstUserAuthentication)
        }

        // A size mismatch means a partial/corrupt download.
        let changed = makeSession(id: "ses_1", voiceBytes: 999, musicBytes: 3400)
        XCTAssertFalse(store.isDownloaded(changed))

        // Excluded from iCloud backup.
        let values = try store.baseDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)

        store.delete(id: "ses_1")
        XCTAssertFalse(store.isDownloaded(session))
        XCTAssertTrue(store.downloadedSessions().isEmpty)
    }

    @MainActor
    func testDownloadStoreDeleteAllAndCache() throws {
        let store = DownloadStore(baseDirectory: tempDir.appendingPathComponent("Present"))
        let a = makeSession(id: "ses_a", voiceBytes: 10, musicBytes: 10)
        let b = makeSession(id: "ses_b", voiceBytes: 10, musicBytes: 10)
        try store.install(a, voiceFile: try writeTemp(10), musicFile: try writeTemp(10))
        try store.install(b, voiceFile: try writeTemp(10), musicFile: try writeTemp(10))
        XCTAssertEqual(store.downloadedIDs.count, 2)

        store.cacheSessions([a, b])
        store.cacheToday(TodayResponse(session: a, nextDailyAt: nil))

        // A fresh instance sees the same state (offline launch).
        let reopened = DownloadStore(baseDirectory: tempDir.appendingPathComponent("Present"))
        XCTAssertEqual(reopened.downloadedIDs, ["ses_a", "ses_b"])
        XCTAssertEqual(reopened.cachedSessions().map(\.id), ["ses_a", "ses_b"])
        XCTAssertEqual(reopened.cachedToday()?.session?.id, "ses_a")

        reopened.deleteAll()
        XCTAssertTrue(reopened.downloadedIDs.isEmpty)
        XCTAssertTrue(reopened.downloadedSessions().isEmpty)

        reopened.wipe()
        XCTAssertTrue(reopened.cachedSessions().isEmpty)
        XCTAssertNil(reopened.cachedToday())
    }

    // MARK: JournalStore

    @MainActor
    func testJournalRoundTrip() throws {
        let dir = tempDir.appendingPathComponent("Journal")
        let journal = JournalStore(directory: dir)
        XCTAssertTrue(journal.entries.isEmpty)

        let first = journal.add(sessionId: "ses_1", sessionTitle: "Arriving",
                                question: "What matters today?", text: "  Breakfast with the kids.  ")
        XCTAssertNotNil(first)
        XCTAssertEqual(first?.text, "Breakfast with the kids.")
        XCTAssertNil(journal.add(sessionId: "ses_1", sessionTitle: "Arriving", question: "Q", text: "   "),
                     "Empty reflections are not saved")
        let second = journal.add(sessionId: "ses_2", sessionTitle: "Evening", question: "Q2", text: "Walked slowly.")
        XCTAssertEqual(journal.entries.count, 2)
        XCTAssertEqual(journal.entries(for: "ses_1").count, 1)

        // Persisted with complete protection.
        let reopened = JournalStore(directory: dir)
        XCTAssertEqual(reopened.entries.count, 2)
        XCTAssertEqual(Set(reopened.entries.map(\.text)), ["Breakfast with the kids.", "Walked slowly."])

        reopened.update(first!.id, text: "Breakfast, unhurried.")
        XCTAssertEqual(JournalStore(directory: dir).entries(for: "ses_1").first?.text, "Breakfast, unhurried.")

        reopened.delete(second!.id)
        XCTAssertEqual(JournalStore(directory: dir).entries.count, 1)

        reopened.deleteAll()
        XCTAssertTrue(JournalStore(directory: dir).entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reopened.fileURL.path))
    }

    @MainActor
    func testJournalUpdateToEmptyDeletes() {
        let journal = JournalStore(directory: tempDir.appendingPathComponent("J2"))
        let entry = journal.add(sessionId: "s", sessionTitle: "t", question: "q", text: "something")!
        journal.update(entry.id, text: "  ")
        XCTAssertTrue(journal.entries.isEmpty)
    }
}
