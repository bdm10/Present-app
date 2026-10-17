import Foundation

/// Small on-device preferences. Nothing sensitive lives here
/// (the server token is in the Keychain, the journal in a protected file).
enum LocalSettings {
    private static var defaults: UserDefaults { .standard }

    private enum Key {
        static let connection = "present.connection"        // "demo" | "server"
        static let serverURL = "present.serverURL"
        static let voiceVolume = "present.voiceVolume"
        static let musicVolume = "present.musicVolume"
        static let journalLock = "present.journalLock"
        static let demoFavorite = "present.demoFavorite"
        static let localReminder = "present.localReminder"
        static let lastRegisteredPushToken = "present.lastPushToken"
    }

    static let tokenAccount = "serverToken"

    static var connection: String? {
        get { defaults.string(forKey: Key.connection) }
        set { defaults.set(newValue, forKey: Key.connection) }
    }

    static var serverURL: String? {
        get { defaults.string(forKey: Key.serverURL) }
        set { defaults.set(newValue, forKey: Key.serverURL) }
    }

    static var voiceVolume: Float {
        get { defaults.object(forKey: Key.voiceVolume) as? Float ?? 1.0 }
        set { defaults.set(newValue, forKey: Key.voiceVolume) }
    }

    static var musicVolume: Float {
        get { defaults.object(forKey: Key.musicVolume) as? Float ?? 0.6 }
        set { defaults.set(newValue, forKey: Key.musicVolume) }
    }

    static var journalLockEnabled: Bool {
        get { defaults.bool(forKey: Key.journalLock) }
        set { defaults.set(newValue, forKey: Key.journalLock) }
    }

    static var demoFavorite: Bool {
        get { defaults.bool(forKey: Key.demoFavorite) }
        set { defaults.set(newValue, forKey: Key.demoFavorite) }
    }

    static var localReminderEnabled: Bool {
        get { defaults.bool(forKey: Key.localReminder) }
        set { defaults.set(newValue, forKey: Key.localReminder) }
    }

    static var lastRegisteredPushToken: String? {
        get { defaults.string(forKey: Key.lastRegisteredPushToken) }
        set { defaults.set(newValue, forKey: Key.lastRegisteredPushToken) }
    }

    /// Removes every preference this app has written.
    static func reset() {
        if let bundleID = Bundle.main.bundleIdentifier {
            defaults.removePersistentDomain(forName: bundleID)
        }
        for key in [Key.connection, Key.serverURL, Key.voiceVolume, Key.musicVolume, Key.journalLock,
                    Key.demoFavorite, Key.localReminder, Key.lastRegisteredPushToken] {
            defaults.removeObject(forKey: key)
        }
        Keychain.delete(tokenAccount)
    }
}
