import AVFoundation
import Foundation
import Observation

/// Plays short voice and music previews in Settings.
/// AVPlayer can't attach our auth header, so previews are fetched then played from memory.
@MainActor
@Observable
final class PreviewPlayer {
    private(set) var playingID: String?
    private(set) var loadingID: String?

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private let delegateProxy = AudioPlayerDelegateProxy()
    @ObservationIgnored private var cache: [String: Data] = [:]

    init() {
        delegateProxy.onFinish = { [weak self] in
            self?.playingID = nil
        }
    }

    func toggle(id: String, path: String, api: APIClient?, sessionPlayer: SessionPlayer) async {
        if playingID == id {
            stop()
            return
        }
        stop()
        guard let api else { return }
        if sessionPlayer.isPlaying { sessionPlayer.pause() }
        loadingID = id
        defer { if loadingID == id { loadingID = nil } }
        do {
            let data: Data
            if let cached = cache[path] {
                data = cached
            } else {
                data = try await api.data(at: path)
                cache[path] = data
            }
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
            let newPlayer = try AVAudioPlayer(data: data)
            newPlayer.delegate = delegateProxy
            newPlayer.prepareToPlay()
            newPlayer.play()
            player = newPlayer
            playingID = id
        } catch {
            playingID = nil
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playingID = nil
    }
}
