import Foundation
import AVFoundation
import MediaPlayer

class AudioPlayerManager {
    static let shared = AudioPlayerManager()
    private var player: AVPlayer?
    private(set) var isPlaying = false
    private(set) var currentSong: SongItem?

    var onStateChanged: ((Bool, String) -> Void)?

    private init() {
        setupAudioSession()
        setupRemoteCommands()
    }

    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("AudioSession error: \(error)")
        }
    }

    func play(song: SongItem, streamURL: URL) {
        currentSong = song
        let playerItem = AVPlayerItem(url: streamURL)
        player = AVPlayer(playerItem: playerItem)
        player?.play()
        isPlaying = true
        updateNowPlayingInfo(song: song)
        onStateChanged?(true, "\(song.title) - \(song.artist)")
    }

    func togglePlayPause() {
        guard let player = player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
        if let song = currentSong {
            onStateChanged?(isPlaying, "\(song.title) - \(song.artist)")
        }
    }

    private func updateNowPlayingInfo(song: SongItem) {
        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = song.title
        info[MPMediaItemPropertyArtist] = song.artist
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func setupRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }
    }
}