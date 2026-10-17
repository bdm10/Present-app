import AVFoundation
import XCTest
@testable import Present

final class SessionPlayerTests: XCTestCase {
    private struct DemoStems {
        let session: Session
        let voice: URL
        let music: URL
    }

    /// The bundled demo session (tests run hosted inside the app, so Bundle.main is the app).
    private func demoStems() throws -> DemoStems {
        let folder = try XCTUnwrap(Bundle.main.url(forResource: "DemoSession", withExtension: nil),
                                   "DemoSession folder must be bundled with the app")
        let data = try Data(contentsOf: folder.appendingPathComponent("session.json"))
        let session = try JSONDecoder().decode(Session.self, from: data)
        let voice = folder.appendingPathComponent("voice.m4a")
        let music = folder.appendingPathComponent("music.m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: voice.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: music.path))
        return DemoStems(session: session, voice: voice, music: music)
    }

    /// Headless CI simulators sometimes have no usable audio device; AVAudioPlayer then
    /// refuses to start. Skip (loudly) rather than report a false failure.
    @MainActor
    private func skipIfNoAudioOutput(_ player: SessionPlayer) async throws {
        if AVAudioSession.sharedInstance().currentRoute.outputs.isEmpty {
            throw XCTSkip("No audio output route on this machine; position checks need one.")
        }
        try await Task.sleep(nanoseconds: 400_000_000)
        if !player.voicePlayerIsPlaying {
            throw XCTSkip("AVAudioPlayer could not start (no audio device available to the simulator).")
        }
    }

    func testInfoPlistAllowsBackgroundAudio() {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        XCTAssertTrue(modes.contains("audio"), "Background audio mode is required for screen-locked playback")
        let tasks = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
        XCTAssertTrue(tasks.contains(BackgroundRefresh.identifier))
    }

    @MainActor
    func testLoadsBundledDemoStemsWithMatchingDurations() throws {
        let stems = try demoStems()
        let player = SessionPlayer()
        try player.load(session: stems.session, voiceURL: stems.voice, musicURL: stems.music)
        defer { player.unload() }

        XCTAssertTrue(player.isLoaded)
        XCTAssertFalse(player.isPlaying)
        XCTAssertGreaterThan(player.duration, 60)
        let musicDuration = try AVAudioPlayer(contentsOf: stems.music).duration
        XCTAssertEqual(player.duration, musicDuration, accuracy: 0.5, "Stems must have the same length")
        if let expected = stems.session.durationSeconds {
            XCTAssertEqual(player.duration, expected, accuracy: 1.0)
        }
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .playback)
    }

    @MainActor
    func testSeekKeepsStemsAlignedAndVolumesAreIndependent() throws {
        let stems = try demoStems()
        let player = SessionPlayer()
        let originalVoice = player.voiceVolume
        let originalMusic = player.musicVolume
        try player.load(session: stems.session, voiceURL: stems.voice, musicURL: stems.music)
        defer {
            player.setVoiceVolume(originalVoice)
            player.setMusicVolume(originalMusic)
            player.unload()
        }

        player.seek(to: 42)
        XCTAssertEqual(player.currentTime, 42, accuracy: 0.01)
        XCTAssertEqual(player.voicePosition, 42, accuracy: 0.05)
        XCTAssertEqual(player.musicPosition, 42, accuracy: 0.05)

        player.skip(by: -15)
        XCTAssertEqual(player.voicePosition, 27, accuracy: 0.05)
        XCTAssertEqual(player.musicPosition, 27, accuracy: 0.05)

        player.seek(to: -10)
        XCTAssertEqual(player.voicePosition, 0, accuracy: 0.05)

        player.setVoiceVolume(0.9)
        player.setMusicVolume(0.25)
        XCTAssertEqual(player.voiceVolume, 0.9, accuracy: 0.001)
        XCTAssertEqual(player.musicVolume, 0.25, accuracy: 0.001)
        XCTAssertEqual(player.voicePlayerVolume, 0.9, accuracy: 0.001)
        XCTAssertEqual(LocalSettings.musicVolume, 0.25, accuracy: 0.001, "Volumes persist between sessions")
    }

    @MainActor
    func testPlaysBothStemsInSyncAndPauses() async throws {
        let stems = try demoStems()
        let player = SessionPlayer()
        try player.load(session: stems.session, voiceURL: stems.voice, musicURL: stems.music)
        defer { player.unload() }

        player.play()
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .playback,
                       "The .playback category keeps audio going when the screen locks")

        try await skipIfNoAudioOutput(player)

        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertTrue(player.voicePlayerIsPlaying)
        XCTAssertTrue(player.musicPlayerIsPlaying)
        XCTAssertGreaterThan(player.voicePosition, 0.5, "Voice should be advancing")
        XCTAssertEqual(player.voicePosition, player.musicPosition, accuracy: 0.1, "Stems must stay in sync")

        player.pause()
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.voicePlayerIsPlaying)
        let pausedAt = player.voicePosition
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(player.voicePosition, pausedAt, accuracy: 0.01, "Paused voice must not advance")
        XCTAssertFalse(player.musicPlayerIsPlaying, "Music pauses after its short fade")

        player.play()
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(player.voicePosition, player.musicPosition, accuracy: 0.1, "Resume re-aligns the stems")
    }

    @MainActor
    func testFastFinishMarksSessionFinished() async throws {
        let stems = try demoStems()
        let player = SessionPlayer()
        try player.load(session: stems.session, voiceURL: stems.voice, musicURL: stems.music)
        defer { player.unload() }

        var finished: Session?
        player.onFinish = { finished = $0 }
        player.fastFinishAfter = 1.0
        player.seek(to: 1.2)
        player.play()

        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertTrue(player.didFinish)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(finished?.id, stems.session.id)
    }
}
