import AVKit
import MediaPlayer
import OSLog
import UIKit

/// Owns the system media session for generated audio, including lock-screen
/// metadata, progress, artwork, and remote playback controls.
final class GeneratedAudioNowPlayingCoordinator {
    static let shared = GeneratedAudioNowPlayingCoordinator()
    private static let logger = Logger(
        subsystem: "com.phantasm.app",
        category: "GeneratedAudioNowPlaying"
    )
    private static let appArtwork: MPMediaItemArtwork? = {
        guard let image = UIImage(named: "Logo") else { return nil }
        return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }()

    private weak var player: AVPlayer?
    private var duration = 0.0
    private var isPlaying = false
    private var onPlaybackChanged: ((Bool) -> Void)?
    private var onPositionChanged: ((Double) -> Void)?
    private var commandsConfigured = false
    private var nowPlayingSession: MPNowPlayingSession?

    private init() {}

    func prepareForPlayback() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playback,
            mode: .default,
            policy: .longFormAudio,
            options: []
        )
        try session.setActive(true)
    }

    func activate(
        player: AVPlayer,
        duration: Double,
        onPlaybackChanged: @escaping (Bool) -> Void,
        onPositionChanged: @escaping (Double) -> Void
    ) {
        if let activePlayer = self.player, activePlayer !== player {
            activePlayer.pause()
            notifyPlaybackChanged(false)
            tearDownSession()
        }

        self.player = player
        self.duration = max(duration, 0)
        isPlaying = true
        self.onPlaybackChanged = onPlaybackChanged
        self.onPositionChanged = onPositionChanged

        if nowPlayingSession == nil {
            let session = MPNowPlayingSession(players: [player])
            session.automaticallyPublishesNowPlayingInfo = false
            nowPlayingSession = session
            commandsConfigured = false
        }
        UIApplication.shared.beginReceivingRemoteControlEvents()
        configureRemoteCommandsIfNeeded()
        setRemoteCommandsEnabled(true)
        publishNowPlayingInfo()
        nowPlayingSession?.becomeActiveIfPossible { isActive in
            Self.logger.info("Now Playing session active: \(isActive, privacy: .public)")
        }
    }

    func updatePlaybackState(
        for player: AVPlayer,
        duration: Double,
        isPlaying: Bool,
        elapsedTime: Double? = nil
    ) {
        guard self.player === player else { return }
        self.duration = max(duration, 0)
        self.isPlaying = isPlaying
        publishNowPlayingInfo(elapsedTime: elapsedTime)
        if let elapsedTime {
            notifyPositionChanged(elapsedTime)
        }
    }

    func updateDuration(for player: AVPlayer, duration: Double) {
        guard self.player === player else { return }
        self.duration = max(duration, 0)
        nowPlayingSession?.remoteCommandCenter.changePlaybackPositionCommand.isEnabled = duration > 0
        publishNowPlayingInfo()
    }

    func deactivate(player: AVPlayer) {
        guard self.player === player else { return }
        tearDownSession()
        self.player = nil
        duration = 0
        isPlaying = false
        onPlaybackChanged = nil
        onPositionChanged = nil
    }

    private func configureRemoteCommandsIfNeeded() {
        guard !commandsConfigured else { return }
        guard let commandCenter = nowPlayingSession?.remoteCommandCenter else { return }
        commandsConfigured = true

        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self, let player = self.player else { return .noSuchContent }
            try? AVAudioSession.sharedInstance().setActive(true)
            player.play()
            self.isPlaying = true
            self.publishNowPlayingInfo()
            self.notifyPlaybackChanged(true)
            return .success
        }

        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self, let player = self.player else { return .noSuchContent }
            player.pause()
            self.isPlaying = false
            self.publishNowPlayingInfo()
            self.notifyPlaybackChanged(false)
            return .success
        }

        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self, let player = self.player else { return .noSuchContent }
            self.isPlaying.toggle()
            if self.isPlaying {
                try? AVAudioSession.sharedInstance().setActive(true)
                player.play()
            } else {
                player.pause()
            }
            self.publishNowPlayingInfo()
            self.notifyPlaybackChanged(self.isPlaying)
            return .success
        }

        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self,
                  let player = self.player,
                  let event = event as? MPChangePlaybackPositionCommandEvent,
                  self.duration > 0 else { return .noSuchContent }
            let position = min(max(event.positionTime, 0), self.duration)
            player.seek(
                to: CMTime(seconds: position, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
            self.publishNowPlayingInfo(elapsedTime: position)
            self.notifyPositionChanged(position)
            return .success
        }
    }

    private func setRemoteCommandsEnabled(_ enabled: Bool) {
        guard let commandCenter = nowPlayingSession?.remoteCommandCenter else { return }
        commandCenter.playCommand.isEnabled = enabled
        commandCenter.pauseCommand.isEnabled = enabled
        commandCenter.togglePlayPauseCommand.isEnabled = enabled
        commandCenter.changePlaybackPositionCommand.isEnabled = enabled && duration > 0
    }

    private func publishNowPlayingInfo(elapsedTime: Double? = nil) {
        guard let player, let nowPlayingSession else { return }
        let rawTime = elapsedTime ?? player.currentTime().seconds
        let finiteTime = rawTime.isFinite ? max(rawTime, 0) : 0
        let currentTime = duration > 0 ? min(finiteTime, duration) : finiteTime
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: "Generated Audio",
            MPMediaItemPropertyArtist: "Phantasm",
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyIsLiveStream: false,
        ]
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if let appArtwork = Self.appArtwork {
            info[MPMediaItemPropertyArtwork] = appArtwork
        }
        nowPlayingSession.nowPlayingInfoCenter.nowPlayingInfo = info
    }

    private func tearDownSession() {
        setRemoteCommandsEnabled(false)
        nowPlayingSession?.nowPlayingInfoCenter.nowPlayingInfo = nil
        nowPlayingSession = nil
        commandsConfigured = false
        UIApplication.shared.endReceivingRemoteControlEvents()
    }

    private func notifyPlaybackChanged(_ isPlaying: Bool) {
        let callback = onPlaybackChanged
        DispatchQueue.main.async { callback?(isPlaying) }
    }

    private func notifyPositionChanged(_ position: Double) {
        let callback = onPositionChanged
        DispatchQueue.main.async { callback?(position) }
    }
}
