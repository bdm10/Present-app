import AVFoundation
import MediaPlayer
import Observation
import UIKit

/// Bridges AVAudioPlayerDelegate callbacks back to the main actor.
final class AudioPlayerDelegateProxy: NSObject, AVAudioPlayerDelegate {
    var onFinish: (@MainActor () -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let callback = onFinish
        Task { @MainActor in callback?() }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let callback = onFinish
        Task { @MainActor in callback?() }
    }
}

/// Plays a session's two stems (voice + music) in sample-aligned sync with
/// independent volumes, background playback, and lock-screen controls.
@MainActor
@Observable
final class SessionPlayer {
    private(set) var session: Session?
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var didFinish = false
    private(set) var voiceVolume: Float
    private(set) var musicVolume: Float

    /// Test hook: finish the session once playback passes this many seconds.
    var fastFinishAfter: TimeInterval?

    @ObservationIgnored var onFinish: ((Session) -> Void)?

    @ObservationIgnored private var voicePlayer: AVAudioPlayer?
    @ObservationIgnored private var musicPlayer: AVAudioPlayer?
    @ObservationIgnored private var progressTimer: Timer?
    @ObservationIgnored private let delegateProxy = AudioPlayerDelegateProxy()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var remoteCommandsConfigured = false
    @ObservationIgnored private var musicFadeGeneration = 0
    @ObservationIgnored private var resumeAfterInterruption = false

    var isLoaded: Bool { session != nil }
    var remaining: TimeInterval { max(0, duration - currentTime) }
    var progress: Double { duration > 0 ? min(1, currentTime / duration) : 0 }

    init() {
        voiceVolume = LocalSettings.voiceVolume
        musicVolume = LocalSettings.musicVolume
        delegateProxy.onFinish = { [weak self] in
            self?.finish()
        }
        observeAudioSession()
    }

    // MARK: Loading

    func load(session: Session, voiceURL: URL, musicURL: URL) throws {
        resetPlayers()
        let voice = try AVAudioPlayer(contentsOf: voiceURL)
        let music = try AVAudioPlayer(contentsOf: musicURL)
        voice.delegate = delegateProxy
        voice.volume = voiceVolume
        music.volume = musicVolume
        voice.prepareToPlay()
        music.prepareToPlay()

        voicePlayer = voice
        musicPlayer = music
        self.session = session
        duration = voice.duration > 0 ? voice.duration : (session.durationSeconds ?? 0)
        currentTime = 0
        didFinish = false
        isPlaying = false

        configureAudioSession()
        configureRemoteCommands()
        updateNowPlaying()
    }

    /// Stops playback and forgets the current session.
    func unload() {
        resetPlayers()
        session = nil
        duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        deactivateAudioSession()
    }

    private func resetPlayers() {
        stopTimer()
        musicFadeGeneration += 1
        voicePlayer?.stop()
        musicPlayer?.stop()
        voicePlayer = nil
        musicPlayer = nil
        isPlaying = false
        didFinish = false
        currentTime = 0
    }

    // MARK: Transport

    func play() {
        guard let voice = voicePlayer, let music = musicPlayer else { return }
        if didFinish {
            voice.currentTime = 0
            currentTime = 0
            didFinish = false
        }
        activateAudioSession()

        // Cancel any pending music pause from a previous fade-out, then line the stems up.
        musicFadeGeneration += 1
        if music.isPlaying { music.pause() }
        music.currentTime = voice.currentTime
        music.volume = 0

        let startAt = voice.deviceCurrentTime + 0.08
        voice.play(atTime: startAt)
        music.play(atTime: startAt)
        music.setVolume(musicVolume, fadeDuration: 0.8)

        isPlaying = true
        startTimer()
        updateNowPlaying()
    }

    func pause() {
        guard let voice = voicePlayer else { return }
        voice.pause()
        currentTime = voice.currentTime
        isPlaying = false
        stopTimer()
        fadeOutAndPauseMusic(over: 0.35)
        updateNowPlaying()
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func seek(to time: TimeInterval) {
        guard let voice = voicePlayer, let music = musicPlayer else { return }
        let target = min(max(0, time), max(0, duration - 0.5))
        let wasPlaying = isPlaying
        musicFadeGeneration += 1
        voice.pause()
        music.pause()
        voice.currentTime = target
        music.currentTime = target
        currentTime = target
        if wasPlaying {
            music.volume = musicVolume
            let startAt = voice.deviceCurrentTime + 0.05
            voice.play(atTime: startAt)
            music.play(atTime: startAt)
        }
        updateNowPlaying()
    }

    func skip(by delta: TimeInterval) {
        let base = voicePlayer?.currentTime ?? currentTime
        seek(to: base + delta)
    }

    func setVoiceVolume(_ value: Float) {
        let v = min(max(value, 0), 1)
        voiceVolume = v
        voicePlayer?.volume = v
        LocalSettings.voiceVolume = v
    }

    func setMusicVolume(_ value: Float) {
        let v = min(max(value, 0), 1)
        musicVolume = v
        if isPlaying {
            musicPlayer?.volume = v
        }
        LocalSettings.musicVolume = v
    }

    // MARK: Finishing

    private func finish() {
        guard session != nil, !didFinish else { return }
        voicePlayer?.pause()
        isPlaying = false
        didFinish = true
        currentTime = duration
        stopTimer()
        fadeOutAndPauseMusic(over: 1.5)
        updateNowPlaying()
        if let session {
            onFinish?(session)
        }
    }

    private func fadeOutAndPauseMusic(over seconds: TimeInterval) {
        guard let music = musicPlayer else { return }
        musicFadeGeneration += 1
        let generation = musicFadeGeneration
        music.setVolume(0, fadeDuration: seconds)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((seconds + 0.05) * 1_000_000_000))
            guard let self, self.musicFadeGeneration == generation else { return }
            self.musicPlayer?.pause()
            if self.didFinish {
                self.deactivateAudioSession()
            }
        }
    }

    // MARK: Progress

    private func startTimer() {
        progressTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { () -> Void in
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    private func stopTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func tick() {
        guard isPlaying, let voice = voicePlayer else { return }
        currentTime = voice.currentTime
        if let fast = fastFinishAfter, currentTime >= fast {
            finish()
            return
        }
        if duration > 0, currentTime >= duration - 0.3 {
            finish()
            return
        }
        // Gentle drift correction: stems should never wander apart audibly.
        if let music = musicPlayer, music.isPlaying, abs(music.currentTime - voice.currentTime) > 0.2 {
            music.currentTime = voice.currentTime
        }
    }

    // MARK: Audio session

    private func configureAudioSession() {
        do {
            // .playback keeps audio going with the screen locked and the silent switch on.
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
        } catch {
            print("Present: audio session category error: \(error)")
        }
    }

    private func activateAudioSession() {
        configureAudioSession()
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Present: audio session activation error: \(error)")
        }
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        let interruption = center.addObserver(forName: AVAudioSession.interruptionNotification,
                                              object: session, queue: .main) { [weak self] note in
            guard let info = note.userInfo,
                  let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
            let rawOptions = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
            let began = type == .began
            MainActor.assumeIsolated { () -> Void in
                self?.handleInterruption(began: began, shouldResume: shouldResume)
            }
        }

        let routeChange = center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                             object: session, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
            if reason == .oldDeviceUnavailable {
                // Headphones unplugged: pause rather than suddenly play from the speaker.
                MainActor.assumeIsolated { () -> Void in
                    if self?.isPlaying == true { self?.pause() }
                }
            }
        }

        observers = [interruption, routeChange]
    }

    private func handleInterruption(began: Bool, shouldResume: Bool) {
        if began {
            if isPlaying {
                resumeAfterInterruption = true
                pause()
            }
        } else {
            if shouldResume && resumeAfterInterruption {
                play()
            }
            resumeAfterInterruption = false
        }
    }

    // MARK: Lock screen

    private func configureRemoteCommands() {
        guard !remoteCommandsConfigured else { return }
        remoteCommandsConfigured = true
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.play() }
            return .success
        }
        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.skipBackwardCommand.isEnabled = true
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(by: -15) }
            return .success
        }
        center.skipForwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(by: 15) }
            return .success
        }
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let target = positionEvent.positionTime
            Task { @MainActor in self?.seek(to: target) }
            return .success
        }
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
    }

    private func updateNowPlaying() {
        guard let session else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: session.displayTitle,
            MPMediaItemPropertyArtist: "Present",
            MPMediaItemPropertyAlbumTitle: session.theme.displayName,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: voicePlayer?.currentTime ?? currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        info[MPMediaItemPropertyArtwork] = NowPlayingArtwork.shared
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: Test inspection

    var voicePosition: TimeInterval { voicePlayer?.currentTime ?? 0 }
    var musicPosition: TimeInterval { musicPlayer?.currentTime ?? 0 }
    var voicePlayerVolume: Float { voicePlayer?.volume ?? 0 }
    var musicPlayerVolume: Float { musicPlayer?.volume ?? 0 }
    var voicePlayerIsPlaying: Bool { voicePlayer?.isPlaying ?? false }
    var musicPlayerIsPlaying: Bool { musicPlayer?.isPlaying ?? false }
}
