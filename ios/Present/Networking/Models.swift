import Foundation

// Mirrors docs/API.md. JSON keys are camelCase, matching Swift property names.

enum Theme: String, Codable, CaseIterable, Identifiable, Hashable {
    case presence
    case gratitude
    case stress
    case sleep
    case family
    case lettingGoOfWork = "letting-go-of-work"
    case slowingDown = "slowing-down"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .presence: return "Presence"
        case .gratitude: return "Gratitude"
        case .stress: return "Stress relief"
        case .sleep: return "Sleep"
        case .family: return "Family connection"
        case .lettingGoOfWork: return "Letting go of work"
        case .slowingDown: return "Slowing down"
        }
    }

    var symbol: String {
        switch self {
        case .presence: return "circle.dotted"
        case .gratitude: return "leaf"
        case .stress: return "wind"
        case .sleep: return "moon.stars"
        case .family: return "heart"
        case .lettingGoOfWork: return "door.left.hand.open"
        case .slowingDown: return "tortoise"
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Theme(rawValue: raw) ?? .presence
    }
}

enum SessionStatus: String, Codable, Hashable {
    case queued, generating, ready, failed

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SessionStatus(rawValue: raw) ?? .queued
    }

    var isInProgress: Bool { self == .queued || self == .generating }
}

enum SessionKind: String, Codable, Hashable {
    case daily
    case onDemand = "on_demand"

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SessionKind(rawValue: raw) ?? .onDemand
    }
}

struct SessionProviders: Codable, Hashable {
    var script: String
    var voice: String
    var music: String
}

struct SessionAudio: Codable, Hashable {
    var voiceUrl: String
    var musicUrl: String
    var voiceBytes: Int
    var musicBytes: Int
}

struct TranscriptLine: Codable, Hashable {
    var text: String
    var startSeconds: Double
}

struct Session: Codable, Identifiable, Hashable {
    var id: String
    var kind: SessionKind
    var localDate: String
    var createdAt: String
    var status: SessionStatus
    var statusDetail: String?
    var theme: Theme
    var durationMinutes: Int
    var title: String?
    var summary: String?
    var reflectionQuestion: String?
    var durationSeconds: Double?
    var favorite: Bool
    var demo: Bool
    /// The server removed this session's audio to save space (copies on the phone still play).
    var archived: Bool?
    var providers: SessionProviders?
    var voiceName: String?
    var musicTitle: String?
    var audio: SessionAudio?
    var transcript: [TranscriptLine]?

    var displayTitle: String { title ?? "A session is taking shape" }

    var createdDate: Date? { ISODate.parse(createdAt) }

    /// The local calendar day the session belongs to, for display.
    var day: Date? {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: localDate) ?? createdDate
    }

    var fallbackReflectionQuestion: String {
        reflectionQuestion ?? "What would it look like to carry a little of this stillness into the next hour?"
    }
}

struct UserProfile: Codable, Hashable {
    var name: String
    var lovedOnes: String
    var context: String

    static let empty = UserProfile(name: "", lovedOnes: "", context: "")
}

struct UserSettings: Codable, Hashable {
    var timeZone: String
    var dailyEnabled: Bool
    var dailyTime: String
    var defaultDurationMinutes: Int
    var themes: [Theme]
    var voiceId: String
    var musicTrackId: String
    var notifyWhenReady: Bool
    var profile: UserProfile

    /// "HH:mm" → hour/minute components.
    var dailyTimeComponents: DateComponents {
        let parts = dailyTime.split(separator: ":").compactMap { Int($0) }
        var c = DateComponents()
        c.hour = parts.first ?? 7
        c.minute = parts.count > 1 ? parts[1] : 0
        return c
    }

    static func formatTime(hour: Int, minute: Int) -> String {
        String(format: "%02d:%02d", hour, minute)
    }
}

enum ProviderMode: String, Codable, Hashable {
    case live, demo

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ProviderMode(rawValue: raw) ?? .demo
    }
}

struct ProviderInfo: Codable, Hashable {
    var mode: ProviderMode
    var name: String
    var detail: String
}

struct PushInfo: Codable, Hashable {
    var configured: Bool
    var detail: String
}

struct ServerStatus: Codable, Hashable {
    struct Providers: Codable, Hashable {
        var script: ProviderInfo
        var voice: ProviderInfo
        var music: ProviderInfo
        var push: PushInfo
    }

    struct Spend: Codable, Hashable {
        var monthUsd: Double
        var monthLimitUsd: Double
        var dailyOnDemandCount: Int
        var dailyOnDemandLimit: Int
    }

    struct Scheduler: Codable, Hashable {
        var nextRunAt: String?
        var lastError: String?
    }

    var version: String
    var providers: Providers
    var spend: Spend
    var scheduler: Scheduler
}

struct Voice: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var description: String
    var provider: String
    var previewUrl: String
}

struct MusicTrack: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var source: String
    var license: String
    var durationSeconds: Double
    var enabled: Bool
    var previewUrl: String

    var isUpload: Bool { source == "upload" }
}

// MARK: - Response envelopes

struct TodayResponse: Codable {
    var session: Session?
    var nextDailyAt: String?
}

struct SessionsResponse: Codable {
    var sessions: [Session]
}

struct VoicesResponse: Codable {
    var voices: [Voice]
}

struct TracksResponse: Codable {
    var tracks: [MusicTrack]
}

struct APIErrorEnvelope: Codable {
    struct Body: Codable {
        var code: String
        var message: String
    }
    var error: Body
}

// MARK: - Request bodies

struct CreateSessionRequest: Encodable {
    var theme: Theme?
    var durationMinutes: Int?
}

struct FavoriteRequest: Encodable {
    var favorite: Bool
}

struct TrackPatchRequest: Encodable {
    var enabled: Bool?
    var title: String?
}

struct DeviceRequest: Encodable {
    var apnsToken: String
    var environment: String
}

struct DeleteDataRequest: Encodable {
    var confirm = "DELETE"
}

enum ISODate {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ string: String?) -> Date? {
        guard let string else { return nil }
        return withFraction.date(from: string) ?? plain.date(from: string)
    }
}
