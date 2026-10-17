import Foundation
import Observation

/// Keeps session audio on the device so sessions play offline and with the screen locked.
///
/// Layout: Application Support/Present/Sessions/<id>/{voice.m4a, music.m4a, session.json}
/// plus Application Support/Present/Cache/{sessions.json, today.json} for the last-known lists.
///
/// Audio uses `completeUntilFirstUserAuthentication` protection: it must stay readable
/// while the phone is locked so background playback keeps working.
@MainActor
@Observable
final class DownloadStore {
    let baseDirectory: URL
    private(set) var downloadedIDs: Set<String> = []
    private(set) var activeDownloads: Set<String> = []

    @ObservationIgnored private let fileManager = FileManager.default
    @ObservationIgnored private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    @ObservationIgnored private let decoder = JSONDecoder()

    static let audioProtection = FileProtectionType.completeUntilFirstUserAuthentication

    init(baseDirectory: URL? = nil) {
        if let baseDirectory {
            self.baseDirectory = baseDirectory
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.baseDirectory = support.appendingPathComponent("Present", isDirectory: true)
        }
        prepareDirectories()
        downloadedIDs = Set(downloadedSessions().map(\.id))
    }

    // MARK: Paths

    var sessionsDirectory: URL { baseDirectory.appendingPathComponent("Sessions", isDirectory: true) }
    var cacheDirectory: URL { baseDirectory.appendingPathComponent("Cache", isDirectory: true) }

    func directory(for id: String) -> URL {
        sessionsDirectory.appendingPathComponent(Self.safeName(id), isDirectory: true)
    }

    func voiceURL(for id: String) -> URL { directory(for: id).appendingPathComponent("voice.m4a") }
    func musicURL(for id: String) -> URL { directory(for: id).appendingPathComponent("music.m4a") }
    func metadataURL(for id: String) -> URL { directory(for: id).appendingPathComponent("session.json") }

    private static func safeName(_ id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return String(id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }

    private func prepareDirectories() {
        for dir in [baseDirectory, sessionsDirectory, cacheDirectory] {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var base = baseDirectory
        try? base.setResourceValues(values)
    }

    // MARK: Queries

    func isDownloaded(_ session: Session) -> Bool {
        let voice = voiceURL(for: session.id)
        let music = musicURL(for: session.id)
        guard fileManager.fileExists(atPath: voice.path), fileManager.fileExists(atPath: music.path) else {
            return false
        }
        if let audio = session.audio {
            return fileSize(voice) == audio.voiceBytes && fileSize(music) == audio.musicBytes
        }
        return true
    }

    func isDownloading(_ id: String) -> Bool { activeDownloads.contains(id) }

    private func fileSize(_ url: URL) -> Int {
        (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? -1
    }

    /// Sessions whose audio is on this device, newest first.
    func downloadedSessions() -> [Session] {
        guard let ids = try? fileManager.contentsOfDirectory(atPath: sessionsDirectory.path) else { return [] }
        let sessions: [Session] = ids.compactMap { name -> Session? in
            let url = sessionsDirectory.appendingPathComponent(name).appendingPathComponent("session.json")
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(Session.self, from: data)
        }
        return sessions.sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: Download

    func download(_ session: Session, using api: APIClient) async throws {
        guard let audio = session.audio else { throw APIError.invalidResponse }
        if isDownloaded(session) {
            try? writeMetadata(session)
            return
        }
        activeDownloads.insert(session.id)
        defer { activeDownloads.remove(session.id) }

        let voiceTemp = try await api.download(audio.voiceUrl)
        let musicTemp: URL
        do {
            musicTemp = try await api.download(audio.musicUrl)
        } catch {
            try? fileManager.removeItem(at: voiceTemp)
            throw error
        }
        try install(session, voiceFile: voiceTemp, musicFile: musicTemp)
    }

    /// Moves already-downloaded stems into place and records the session.
    func install(_ session: Session, voiceFile: URL, musicFile: URL) throws {
        let dir = directory(for: session.id)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        try replace(voiceURL(for: session.id), with: voiceFile)
        try replace(musicURL(for: session.id), with: musicFile)
        try writeMetadata(session)
        downloadedIDs.insert(session.id)
    }

    private func replace(_ destination: URL, with source: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: source, to: destination)
        try? fileManager.setAttributes([.protectionKey: Self.audioProtection], ofItemAtPath: destination.path)
    }

    /// Keeps the stored copy of a session's metadata (title, favourite…) current.
    func writeMetadata(_ session: Session) throws {
        let dir = directory(for: session.id)
        guard fileManager.fileExists(atPath: dir.path) else { return }
        let data = try encoder.encode(session)
        try data.write(to: metadataURL(for: session.id),
                       options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    // MARK: Delete

    func delete(id: String) {
        try? fileManager.removeItem(at: directory(for: id))
        downloadedIDs.remove(id)
    }

    func deleteAll() {
        try? fileManager.removeItem(at: sessionsDirectory)
        try? fileManager.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        downloadedIDs.removeAll()
    }

    /// Removes downloads and cached lists. Used by "Delete all data" and reset.
    func wipe() {
        deleteAll()
        try? fileManager.removeItem(at: cacheDirectory)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    var totalBytes: Int {
        guard let enumerator = fileManager.enumerator(at: sessionsDirectory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let url as URL in enumerator {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }

    // MARK: Cached lists (offline browsing)

    func cacheSessions(_ sessions: [Session]) {
        writeCache(sessions, name: "sessions.json")
    }

    func cachedSessions() -> [Session] {
        readCache([Session].self, name: "sessions.json") ?? []
    }

    func cacheToday(_ response: TodayResponse) {
        writeCache(response, name: "today.json")
    }

    func cachedToday() -> TodayResponse? {
        readCache(TodayResponse.self, name: "today.json")
    }

    private func writeCache<T: Encodable>(_ value: T, name: String) {
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: cacheDirectory.appendingPathComponent(name),
                        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func readCache<T: Decodable>(_ type: T.Type, name: String) -> T? {
        guard let data = try? Data(contentsOf: cacheDirectory.appendingPathComponent(name)) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }
}
