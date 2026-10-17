import Foundation
import LocalAuthentication
import Observation
import UIKit

enum AppTab: Hashable {
    case today, library, settings
}

enum Connection: Equatable {
    case disconnected
    case demo
    case server(ServerConfig)
}

/// App-wide state and the actions the screens call into.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    // Connection
    var connection: Connection = .disconnected
    var selectedTab: AppTab = .today

    // Server data
    var status: ServerStatus?
    var settings: UserSettings?
    var today: Session?
    var nextDailyAt: Date?
    /// A session the person just asked for; shown on Today until they leave the app.
    var featured: Session?
    var sessions: [Session] = []
    var voices: [Voice] = []
    var tracks: [MusicTrack] = []

    // UI state
    var hasLoadedOnce = false
    var isOffline = false
    var isCreating = false
    var errorMessage: String?
    var preparingSessionID: String?
    var isPlayerPresented = false
    var journalUnlocked = false
    var pushRegistered = false

    // Bundled demo
    let demoSession: Session?
    let demoVoiceURL: URL?
    let demoMusicURL: URL?
    var demoFavorite: Bool = LocalSettings.demoFavorite

    let downloads: DownloadStore
    let journal: JournalStore
    let player: SessionPlayer
    let launch: LaunchOptions

    @ObservationIgnored private var pollTasks: [String: Task<Void, Never>] = [:]

    init(launch: LaunchOptions = .current) {
        self.launch = launch
        if launch.resetState {
            LocalSettings.reset()
            DownloadStore().wipe()
            JournalStore().deleteAll()
        }
        downloads = DownloadStore()
        journal = JournalStore()
        player = SessionPlayer()

        let folder = Bundle.main.url(forResource: "DemoSession", withExtension: nil)
        if let folder,
           let data = try? Data(contentsOf: folder.appendingPathComponent("session.json")),
           let session = try? JSONDecoder().decode(Session.self, from: data) {
            var demo = session
            demo.demo = true
            demoSession = demo
            demoVoiceURL = folder.appendingPathComponent("voice.m4a")
            demoMusicURL = folder.appendingPathComponent("music.m4a")
        } else {
            demoSession = nil
            demoVoiceURL = nil
            demoMusicURL = nil
        }

        player.fastFinishAfter = launch.fastFinish ? 3 : nil
        player.onFinish = { [weak self] _ in
            // Bring the reflection forward even if the player was minimised.
            self?.isPlayerPresented = true
        }

        restoreConnection()
    }

    // MARK: Connection

    var api: APIClient? {
        if case .server(let config) = connection { return APIClient(config: config) }
        return nil
    }

    var isDemo: Bool { connection == .demo }
    var isConnected: Bool { api != nil }

    private func restoreConnection() {
        if let urlString = launch.serverURL, let url = URL(string: urlString) {
            let token = launch.token ?? ""
            Keychain.set(token, for: LocalSettings.tokenAccount)
            LocalSettings.serverURL = urlString
            LocalSettings.connection = "server"
            connection = .server(ServerConfig(baseURL: url, token: token))
        } else if launch.demoOnly {
            LocalSettings.connection = "demo"
            connection = .demo
        } else if LocalSettings.connection == "server",
                  let urlString = LocalSettings.serverURL, let url = URL(string: urlString),
                  let token = Keychain.get(LocalSettings.tokenAccount) {
            connection = .server(ServerConfig(baseURL: url, token: token))
        } else if LocalSettings.connection == "demo" {
            connection = .demo
        } else {
            connection = .disconnected
        }

        if isConnected {
            loadCachedData()
        }
    }

    /// Validates the server and token before saving them.
    func connect(urlString: String, token: String) async throws {
        var trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.lowercased().hasPrefix("http") { trimmed = "https://" + trimmed }
        guard let url = URL(string: trimmed), url.host != nil else {
            throw APIError.server(code: "invalid", message: "That doesn't look like a web address.", status: 0)
        }
        let config = ServerConfig(baseURL: url, token: token.trimmingCharacters(in: .whitespacesAndNewlines))
        let client = APIClient(config: config)
        _ = try await client.status()

        Keychain.set(config.token, for: LocalSettings.tokenAccount)
        LocalSettings.serverURL = url.absoluteString
        LocalSettings.connection = "server"
        connection = .server(config)
        selectedTab = .today
        await refresh()
        await setUpNotifications()
    }

    func enterDemo() {
        LocalSettings.connection = "demo"
        connection = .demo
        selectedTab = .today
    }

    func disconnect() {
        player.unload()
        isPlayerPresented = false
        Keychain.delete(LocalSettings.tokenAccount)
        LocalSettings.connection = nil
        LocalSettings.serverURL = nil
        status = nil
        settings = nil
        today = nil
        featured = nil
        sessions = []
        voices = []
        tracks = []
        connection = .disconnected
    }

    // MARK: Loading

    private func loadCachedData() {
        if let cached = downloads.cachedToday() {
            today = cached.session
            nextDailyAt = ISODate.parse(cached.nextDailyAt)
        }
        sessions = downloads.cachedSessions()
        if sessions.isEmpty {
            sessions = downloads.downloadedSessions()
        }
    }

    /// Pulls everything the screens need. Falls back to cached data when offline.
    func refresh() async {
        guard let api else {
            hasLoadedOnce = true
            return
        }
        do {
            let todayResponse = try await api.today()
            today = todayResponse.session
            nextDailyAt = ISODate.parse(todayResponse.nextDailyAt)
            downloads.cacheToday(todayResponse)
            isOffline = false

            let list = try await api.sessions()
            sessions = list
            downloads.cacheSessions(list)

            if let featuredID = featured?.id {
                featured = list.first { $0.id == featuredID } ?? featured
            }

            status = try? await api.status()
            if let fetched = try? await api.settings() {
                settings = fetched
                await syncTimeZone(fetched)
            }
            errorMessage = nil

            for session in [today, featured].compactMap({ $0 }) where session.status.isInProgress {
                watch(session.id)
            }
            if let today, today.status == .ready {
                await autoDownload(today)
            }
            scheduleBackgroundRefresh()
        } catch APIError.offline {
            isOffline = true
            loadCachedData()
        } catch APIError.unauthorized {
            errorMessage = "Your access token was not accepted. Reconnect in Settings → Server."
        } catch {
            if (error as? URLError) != nil {
                isOffline = true
                loadCachedData()
            } else {
                errorMessage = error.localizedDescription
            }
        }
        hasLoadedOnce = true
    }

    func refreshVoicesAndMusic() async {
        guard let api else { return }
        if let v = try? await api.voices() { voices = v }
        if let t = try? await api.music() { tracks = t }
    }

    private func syncTimeZone(_ current: UserSettings) async {
        let deviceZone = TimeZone.current.identifier
        guard current.timeZone != deviceZone else { return }
        await updateSettings { $0.timeZone = deviceZone }
    }

    /// Called from the background refresh task.
    func backgroundRefresh() async -> Bool {
        guard let api else { return false }
        do {
            let response = try await api.today()
            today = response.session
            nextDailyAt = ISODate.parse(response.nextDailyAt)
            downloads.cacheToday(response)
            if let session = response.session, session.status == .ready {
                try await downloads.download(session, using: api)
            }
            scheduleBackgroundRefresh()
            return true
        } catch {
            scheduleBackgroundRefresh()
            return false
        }
    }

    func scheduleBackgroundRefresh() {
        BackgroundRefresh.schedule(earliest: nextDailyAt ?? Date(timeIntervalSinceNow: 4 * 60 * 60))
    }

    // MARK: Session lookups

    /// The session Today shows.
    var displayedSession: Session? {
        switch connection {
        case .demo: return demoSessionWithFavorite
        case .server: return featured ?? today
        case .disconnected: return nil
        }
    }

    var demoSessionWithFavorite: Session? {
        guard var demo = demoSession else { return nil }
        demo.favorite = demoFavorite
        return demo
    }

    func isBundledDemo(_ session: Session) -> Bool {
        session.id == demoSession?.id
    }

    var librarySessions: [Session] {
        switch connection {
        case .demo:
            return demoSessionWithFavorite.map { [$0] } ?? []
        case .server:
            var list = sessions
            if let featured, !list.contains(where: { $0.id == featured.id }) {
                list.insert(featured, at: 0)
            }
            return list
        case .disconnected:
            return []
        }
    }

    func isAvailableOffline(_ session: Session) -> Bool {
        isBundledDemo(session) || downloads.downloadedIDs.contains(session.id)
    }

    private func apply(_ session: Session) {
        if today?.id == session.id { today = session }
        if featured?.id == session.id { featured = session }
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else if session.status != .queued {
            sessions.insert(session, at: 0)
        }
        if downloads.downloadedIDs.contains(session.id) {
            try? downloads.writeMetadata(session)
        }
    }

    // MARK: Creating sessions

    @discardableResult
    func createSession(theme: Theme?, durationMinutes: Int?) async -> Session? {
        guard let api else { return nil }
        isCreating = true
        defer { isCreating = false }
        do {
            let session = try await api.createSession(theme: theme, durationMinutes: durationMinutes)
            featured = session
            apply(session)
            watch(session.id)
            selectedTab = .today
            errorMessage = nil
            return session
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Polls a generating session every 3 s until it's ready or has failed.
    func watch(_ id: String) {
        guard pollTasks[id] == nil else { return }
        pollTasks[id] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, let api = self.api else { break }
                guard let session = try? await api.session(id: id) else { continue }
                self.apply(session)
                if session.status == .ready {
                    await self.autoDownload(session)
                    break
                }
                if session.status == .failed { break }
            }
            self?.pollTasks[id] = nil
        }
    }

    private func autoDownload(_ session: Session) async {
        guard let api, !downloads.isDownloaded(session), !downloads.isDownloading(session.id) else { return }
        try? await downloads.download(session, using: api)
    }

    // MARK: Playback

    func play(_ session: Session) async {
        if player.session?.id == session.id {
            isPlayerPresented = true
            if !player.isPlaying { player.play() }
            return
        }
        do {
            let voiceURL: URL
            let musicURL: URL
            if isBundledDemo(session), let v = demoVoiceURL, let m = demoMusicURL {
                voiceURL = v
                musicURL = m
            } else {
                if !downloads.isDownloaded(session) {
                    guard let api else { throw APIError.offline }
                    preparingSessionID = session.id
                    defer { preparingSessionID = nil }
                    try await downloads.download(session, using: api)
                }
                voiceURL = downloads.voiceURL(for: session.id)
                musicURL = downloads.musicURL(for: session.id)
            }
            try player.load(session: session, voiceURL: voiceURL, musicURL: musicURL)
            isPlayerPresented = true
            player.play()
            errorMessage = nil
        } catch {
            errorMessage = "This session couldn't be played. \(error.localizedDescription)"
        }
    }

    /// Stops and forgets the current session immediately.
    func stopPlayback() {
        isPlayerPresented = false
        player.unload()
    }

    /// Called when the reflection is saved or skipped.
    func endSession() {
        isPlayerPresented = false
        guard let finishedID = player.session?.id else { return }
        // Let the cover slide away before tearing the player down.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard let self, !self.isPlayerPresented, self.player.session?.id == finishedID else { return }
            self.player.unload()
        }
    }

    // MARK: Favourites, downloads, deletion

    func toggleFavorite(_ session: Session) async {
        if isBundledDemo(session) {
            demoFavorite.toggle()
            LocalSettings.demoFavorite = demoFavorite
            return
        }
        guard let api else { return }
        var optimistic = session
        optimistic.favorite.toggle()
        apply(optimistic)
        do {
            let updated = try await api.setFavorite(id: session.id, favorite: optimistic.favorite)
            apply(updated)
            downloads.cacheSessions(sessions)
        } catch {
            apply(session)
            errorMessage = error.localizedDescription
        }
    }

    func download(_ session: Session) async {
        guard let api else { return }
        do {
            try await downloads.download(session, using: api)
        } catch {
            errorMessage = "Download didn't finish. \(error.localizedDescription)"
        }
    }

    func removeDownload(_ session: Session) {
        if player.session?.id == session.id { stopPlayback() }
        downloads.delete(id: session.id)
    }

    func deleteSession(_ session: Session) async {
        guard let api else { return }
        do {
            try await api.deleteSession(id: session.id)
            if player.session?.id == session.id { stopPlayback() }
            downloads.delete(id: session.id)
            sessions.removeAll { $0.id == session.id }
            if today?.id == session.id { today = nil }
            if featured?.id == session.id { featured = nil }
            downloads.cacheSessions(sessions)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Wipes everything on the server, then everything local that came from it.
    func deleteAllServerData() async -> Bool {
        guard let api else { return false }
        do {
            try await api.deleteAllData()
            player.unload()
            isPlayerPresented = false
            downloads.wipe()
            sessions = []
            today = nil
            featured = nil
            await refresh()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: Settings

    func updateSettings(_ mutate: (inout UserSettings) -> Void) async {
        guard let api, var updated = settings else { return }
        mutate(&updated)
        settings = updated
        do {
            settings = try await api.updateSettings(updated)
            status = try? await api.status()
            if let refreshed = try? await api.today() {
                nextDailyAt = ISODate.parse(refreshed.nextDailyAt)
            }
            await refreshLocalReminder()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Notifications

    func setUpNotifications() async {
        guard isConnected, settings?.notifyWhenReady ?? true else { return }
        let status = await NotificationManager.authorizationStatus()
        if status == .authorized || status == .provisional {
            await NotificationManager.registerForRemoteIfAuthorized()
        }
        await refreshLocalReminder()
    }

    func enableNotifications() async -> Bool {
        let granted = await NotificationManager.requestAuthorization()
        if granted {
            await NotificationManager.registerForRemoteIfAuthorized()
        }
        await refreshLocalReminder()
        return granted
    }

    /// Uses a local reminder only when the server can't push to this device.
    func refreshLocalReminder() async {
        guard let settings, settings.notifyWhenReady, settings.dailyEnabled else {
            NotificationManager.cancelLocalReminder()
            LocalSettings.localReminderEnabled = false
            return
        }
        let serverCanPush = (status?.providers.push.configured ?? false) && pushRegistered
        if serverCanPush {
            NotificationManager.cancelLocalReminder()
            LocalSettings.localReminderEnabled = false
        } else {
            let c = settings.dailyTimeComponents
            await NotificationManager.scheduleLocalReminder(hour: c.hour ?? 7, minute: c.minute ?? 0)
            LocalSettings.localReminderEnabled = true
        }
    }

    var usesLocalReminder: Bool {
        !((status?.providers.push.configured ?? false) && pushRegistered)
    }

    func didRegisterForPush(token: String) async {
        guard let api else { return }
        #if DEBUG
        let environment = "sandbox"
        #else
        let environment = "production"
        #endif
        do {
            try await api.registerDevice(token: token, environment: environment)
            pushRegistered = true
            LocalSettings.lastRegisteredPushToken = token
            await refreshLocalReminder()
        } catch {
            pushRegistered = false
        }
    }

    func didFailToRegisterForPush() async {
        pushRegistered = false
        await refreshLocalReminder()
    }

    // MARK: Journal privacy

    var journalNeedsUnlock: Bool {
        LocalSettings.journalLockEnabled && !journalUnlocked
    }

    func unlockJournal() async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No passcode set: nothing to authenticate against.
            journalUnlocked = true
            return true
        }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                      localizedReason: "Unlock your journal")
            journalUnlocked = ok
            return ok
        } catch {
            return false
        }
    }

    func lockJournal() {
        journalUnlocked = false
    }
}
