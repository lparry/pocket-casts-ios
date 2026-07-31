import AVFoundation
import Foundation
import PocketCastsDataModel

class GoogleCastPlayer: PlaybackProtocol {
    private lazy var castManager: GoogleCastManager = .sharedManager

    private var shouldKeepPlaying = false
    private var episode: BaseEpisode?
    private var needsLoad = false
    private let reportPlaybackError: (PlaybackManager.PlaybackError) -> Void

    init(reportPlaybackError: @escaping (PlaybackManager.PlaybackError) -> Void = { PlaybackManager.shared.playbackDidFail(error: $0) }) {
        self.reportPlaybackError = reportPlaybackError
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - PlaybackProtocol impl

    func loadEpisode(_ episode: BaseEpisode) {
        castManager.cancelPlaybackStart()
        shouldKeepPlaying = false
        self.episode = episode
        needsLoad = true
    }

    func isReadyToPlay() -> Bool {
        castManager.hasCastSession()
    }

    func playing() -> Bool {
        castManager.playing()
    }

    func buffering() -> Bool {
        castManager.buffering()
    }

    func futureBufferAvailable() -> TimeInterval {
        duration() - currentTime()
    }

    func play(completion: (() -> Void)?, failure: (() -> Void)?) {
        guard let episode else {
            failure?()
            return
        }
        if let userEpisode = episode as? UserEpisode, !userEpisode.uploaded() {
            reportPlaybackError(.chromecastError(logMessage: "Unable to cast local file"))
            failure?()
            return
        }
        shouldKeepPlaying = true
        let started: () -> Void = { [weak self] in
            self?.needsLoad = false
            PlaybackManager.shared.playerDidFinishPreparing()
            completion?()
        }
        let failed: () -> Void = { [weak self] in
            self?.shouldKeepPlaying = false
            failure?()
        }
        if needsLoad {
            castManager.playSingleEpisode(episode, completion: started, failure: failed)
        } else {
            castManager.play(episodeUuid: episode.uuid, completion: started, failure: failed)
        }
    }

    func pause() {
        shouldKeepPlaying = false
        castManager.pause()
    }

    func playbackRate() -> Double {
        playing() ? 1.0 : 0
    }

    func setPlaybackRate(_ rate: Double) {
        // we don't support this currently
    }

    func seekTo(_ time: TimeInterval, completion: (() -> Void)?) {
        castManager.seekToTime(time)

        completion?()
    }

    func currentTime() -> TimeInterval {
        if castManager.connectedOrConnectingToDevice() {
            return castManager.streamPosition()
        }

        // if we're not connected, don't trust the time the library gives back, it's often old
        return -1
    }

    func duration() -> TimeInterval {
        castManager.streamDuration()
    }

    func endPlayback(permanent: Bool) {
        castManager.cancelPlaybackStart()
        shouldKeepPlaying = false
        if permanent {
            castManager.endPlayback()
        }
    }

    func effectsDidChange() {
        let speed = Float(PlaybackManager.shared.effects().playbackSpeed)
        castManager.changePlaybackSpeed(speed)
    }

    func supportsSilenceRemoval() -> Bool {
        false
    }

    func supportsVolumeBoost() -> Bool {
        false
    }

    func supportsGoogleCast() -> Bool {
        true
    }

    func supportsStreaming() -> Bool {
        true
    }

    func supportsAirplay2() -> Bool {
        false
    }

    func shouldBePlaying() -> Bool {
        shouldKeepPlaying
    }

    func interruptionDidStart() {
        // we're playing external, so we don't really care
    }

    func routeDidChange(shouldPause: Bool) {
        // we're playing external, so we don't really care
    }

    func internalPlayerForVideoPlayback() -> AVPlayer? {
        nil
    }

    // MARK: - Volume

    func setVolume(_ volume: Float) {
        // not supported
    }

    var currentAudioLevel: Float {
        // not supported
        return 0
    }
}
