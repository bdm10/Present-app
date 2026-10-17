import XCTest
@testable import Present

final class ModelDecodingTests: XCTestCase {
    private let decoder = JSONDecoder()

    func testDecodesReadySession() throws {
        let json = """
        {
          "id": "ses_abc123", "kind": "daily", "localDate": "2026-10-17",
          "createdAt": "2026-10-17T05:40:00.000Z", "status": "ready", "statusDetail": null,
          "theme": "letting-go-of-work", "durationMinutes": 10, "title": "Setting It Down",
          "summary": "A pause to put the workday down.", "reflectionQuestion": "What can wait until tomorrow?",
          "durationSeconds": 600.0, "favorite": true, "demo": false,
          "providers": {"script": "anthropic:claude", "voice": "elevenlabs:eleven_v3:abc", "music": "builtin:warm-pad"},
          "voiceName": "Aria", "musicTitle": "Warm Pad",
          "audio": {"voiceUrl": "/api/sessions/ses_abc123/audio/voice.m4a",
                    "musicUrl": "/api/sessions/ses_abc123/audio/music.m4a",
                    "voiceBytes": 4800000, "musicBytes": 7200000},
          "transcript": [{"text": "Welcome.", "startSeconds": 6.5}]
        }
        """
        let session = try decoder.decode(Session.self, from: Data(json.utf8))
        XCTAssertEqual(session.id, "ses_abc123")
        XCTAssertEqual(session.kind, .daily)
        XCTAssertEqual(session.status, .ready)
        XCTAssertEqual(session.theme, .lettingGoOfWork)
        XCTAssertEqual(session.durationMinutes, 10)
        XCTAssertEqual(session.durationSeconds, 600)
        XCTAssertTrue(session.favorite)
        XCTAssertEqual(session.audio?.voiceBytes, 4_800_000)
        XCTAssertEqual(session.transcript?.first?.startSeconds, 6.5)
        XCTAssertNotNil(session.createdDate)
        XCTAssertNotNil(session.day)
    }

    func testDecodesQueuedSessionWithNulls() throws {
        let json = """
        {"id": "ses_q", "kind": "on_demand", "localDate": "2026-10-17", "createdAt": "2026-10-17T09:00:00Z",
         "status": "queued", "statusDetail": "Waiting to start", "theme": "gratitude", "durationMinutes": 5,
         "title": null, "summary": null, "reflectionQuestion": null, "durationSeconds": null,
         "favorite": false, "demo": true, "providers": null, "voiceName": null, "musicTitle": null,
         "audio": null, "transcript": null}
        """
        let session = try decoder.decode(Session.self, from: Data(json.utf8))
        XCTAssertEqual(session.kind, .onDemand)
        XCTAssertTrue(session.status.isInProgress)
        XCTAssertNil(session.audio)
        XCTAssertFalse(session.displayTitle.isEmpty)
        XCTAssertFalse(session.fallbackReflectionQuestion.isEmpty)
    }

    func testUnknownThemeFallsBackGracefully() throws {
        let json = #"["presence","something-new","sleep"]"#
        let themes = try decoder.decode([Theme].self, from: Data(json.utf8))
        XCTAssertEqual(themes, [.presence, .presence, .sleep])
    }

    func testDecodesSettingsAndRoundTrips() throws {
        let json = """
        {"timeZone": "Europe/Madrid", "dailyEnabled": true, "dailyTime": "06:45",
         "defaultDurationMinutes": 15, "themes": ["presence", "family"], "voiceId": "v1",
         "musicTrackId": "auto", "notifyWhenReady": true,
         "profile": {"name": "Brian", "lovedOnes": "my family", "context": "busy work"}}
        """
        let settings = try decoder.decode(UserSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.dailyTimeComponents.hour, 6)
        XCTAssertEqual(settings.dailyTimeComponents.minute, 45)
        XCTAssertEqual(settings.themes, [.presence, .family])
        XCTAssertEqual(settings.profile.name, "Brian")

        let encoded = try JSONEncoder().encode(settings)
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        XCTAssertEqual(object?["dailyTime"] as? String, "06:45")
        XCTAssertEqual(object?["themes"] as? [String], ["presence", "family"])
        XCTAssertEqual(UserSettings.formatTime(hour: 7, minute: 5), "07:05")
    }

    func testDecodesStatus() throws {
        let json = """
        {"version": "1.0.0",
         "providers": {
            "script": {"mode": "demo", "name": "Prewritten scripts", "detail": "ANTHROPIC_API_KEY not set"},
            "voice": {"mode": "live", "name": "ElevenLabs", "detail": "eleven_v3"},
            "music": {"mode": "live", "name": "Built-in ambient", "detail": "3 tracks"},
            "push": {"configured": false, "detail": "APNs key not configured"}},
         "spend": {"monthUsd": 1.25, "monthLimitUsd": 20, "dailyOnDemandCount": 1, "dailyOnDemandLimit": 5},
         "scheduler": {"nextRunAt": "2026-10-18T05:30:00Z", "lastError": null}}
        """
        let status = try decoder.decode(ServerStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status.providers.script.mode, .demo)
        XCTAssertEqual(status.providers.voice.mode, .live)
        XCTAssertFalse(status.providers.push.configured)
        XCTAssertEqual(status.spend.monthLimitUsd, 20)
        XCTAssertNil(status.scheduler.lastError)
    }

    func testDecodesVoicesTracksAndToday() throws {
        let voices = try decoder.decode(VoicesResponse.self, from: Data("""
        {"voices": [{"id": "v1", "name": "Calm", "description": "Warm, low", "provider": "demo",
                     "previewUrl": "/api/voices/v1/preview.m4a"}]}
        """.utf8))
        XCTAssertEqual(voices.voices.first?.provider, "demo")

        let tracks = try decoder.decode(TracksResponse.self, from: Data("""
        {"tracks": [{"id": "t1", "title": "Warm Pad", "source": "builtin", "license": "Original, CC0",
                     "durationSeconds": 180.5, "enabled": true, "previewUrl": "/api/music/t1/audio.m4a"}]}
        """.utf8))
        XCTAssertFalse(tracks.tracks[0].isUpload)

        let today = try decoder.decode(TodayResponse.self, from: Data(#"{"session": null, "nextDailyAt": "2026-10-18T06:00:00Z"}"#.utf8))
        XCTAssertNil(today.session)
        XCTAssertNotNil(ISODate.parse(today.nextDailyAt))
    }

    func testAPIClientBuildsURLsAndAuthHeader() {
        let client = APIClient(config: ServerConfig(baseURL: URL(string: "https://example.com/")!, token: "secret"))
        let request = client.request("/api/sessions/ses_1/audio/voice.m4a")
        XCTAssertEqual(request.url?.absoluteString, "https://example.com/api/sessions/ses_1/audio/voice.m4a")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(client.url(for: "api/today").absoluteString, "https://example.com/api/today")
    }

    func testLaunchOptionsParsing() {
        let options = LaunchOptions(arguments: ["app", "-PresentServerURL", "http://localhost:8787",
                                                "-PresentToken", "tok", "-PresentResetState", "YES",
                                                "-PresentFastFinish", "YES"])
        XCTAssertEqual(options.serverURL, "http://localhost:8787")
        XCTAssertEqual(options.token, "tok")
        XCTAssertTrue(options.resetState)
        XCTAssertTrue(options.fastFinish)
        XCTAssertFalse(options.demoOnly)
    }
}
