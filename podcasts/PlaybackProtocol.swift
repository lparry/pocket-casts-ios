import AVFoundation
import PocketCastsDataModel

@objc protocol PlaybackProtocol: AnyObject {
    func loadEpisode(_ episode: BaseEpisode)
    func playing() -> Bool
    func buffering() -> Bool
    func futureBufferAvailable() -> TimeInterval
    func play(completion: (() -> Void)?, failure: (() -> Void)?)
    func pause()
    func playbackRate() -> Double
    func setPlaybackRate(_ rate: Double)

    func seekTo(_ time: TimeInterval, completion: (() -> Void)?, failure: (() -> Void)?)
    func currentTime() -> TimeInterval
    func duration() -> TimeInterval

    func endPlayback(permanent: Bool)

    func effectsDidChange()

    func isReadyToPlay() -> Bool

    func supportsSilenceRemoval() -> Bool
    func supportsVolumeBoost() -> Bool
    func supportsGoogleCast() -> Bool
    func supportsStreaming() -> Bool
    func supportsAirplay2() -> Bool

    func shouldBePlaying() -> Bool

    func routeDidChange(shouldPause: Bool)
    func interruptionDidStart()

    func internalPlayerForVideoPlayback() -> AVPlayer?

    func setVolume(_ volume: Float)

    var currentAudioLevel: Float { get }
}
extension PlaybackProtocol {
    func play(completion: (() -> Void)? = nil) {
        play(completion: completion, failure: nil)
    }

    func seekTo(_ time: TimeInterval, completion: (() -> Void)?) {
        seekTo(time, completion: completion, failure: nil)
    }
}

struct PlaybackSeekContext {
    enum CompletionKind: Equatable {
        case sameEpisode
        case completedEpisode
        case invalid
    }

    let episodeUuid: String
    let episodeDuration: TimeInterval
    let playbackGeneration: UUID
    let targetTime: TimeInterval

    func completionKind(currentEpisodeUuid: String?, playbackGeneration: UUID) -> CompletionKind {
        if playbackGeneration == self.playbackGeneration, currentEpisodeUuid == episodeUuid {
            return .sameEpisode
        }
        if targetTime >= episodeDuration, currentEpisodeUuid != episodeUuid {
            return .completedEpisode
        }
        return .invalid
    }
}

/// One terminal result for a playback attempt, including attempts interrupted by another action.
final class PlaybackStartRequest {
    private let lock = NSLock()
    private var finished = false
    private var resolutionHandlers: [() -> Void] = []
    private var timeoutWork: DispatchWorkItem?
    private var completion: (() -> Void)?
    private var failure: (() -> Void)?

    init(completion: (() -> Void)?, failure: (() -> Void)?) {
        self.completion = completion
        self.failure = failure
    }

    /// Startup must complete while the background caller still has execution time.
    static let startupTimeout: TimeInterval = 25

    func startTimeout(after interval: TimeInterval = startupTimeout, onTimeout: @escaping () -> Void = {}) {
        let work = DispatchWorkItem { [weak self] in
            self?.resolve(success: false, beforeCallback: onTimeout)
        }
        lock.lock()
        guard !finished else { lock.unlock(); return }
        timeoutWork?.cancel()
        timeoutWork = work
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: work)
    }

    func whenResolved(_ handler: @escaping () -> Void) {
        lock.lock()
        if finished {
            lock.unlock()
            handler()
        } else {
            resolutionHandlers.append(handler)
            lock.unlock()
        }
    }

    var hasTimeout: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !finished && timeoutWork != nil
    }

    var isPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !finished
    }

    func finish(success: Bool) {
        resolve(success: success)
    }

    /// The caller has transferred completion ownership to a replacement player.
    func discard() {
        resolve(success: nil)
    }

    private func resolve(success: Bool?, beforeCallback: (() -> Void)? = nil) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        timeoutWork?.cancel()
        timeoutWork = nil
        let handlers = resolutionHandlers
        resolutionHandlers = []
        let callback: (() -> Void)?
        if let success {
            callback = success ? completion : failure
        } else {
            callback = nil
        }
        completion = nil
        failure = nil
        lock.unlock()
        beforeCallback?()
        handlers.forEach { $0() }
        callback?()
    }
}

final class PlaybackStartRequests {
    private let lock = NSLock()
    private var requests: [PlaybackStartRequest] = []
    private var currentGeneration = UUID()

    var hasBoundedPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return requests.contains { $0.hasTimeout }
    }

    var generation: UUID {
        lock.lock()
        defer { lock.unlock() }
        return currentGeneration
    }

    func begin(completion: (() -> Void)?, failure: (() -> Void)?) -> PlaybackStartRequest {
        let request = PlaybackStartRequest(completion: completion, failure: failure)
        lock.lock()
        requests.removeAll { !$0.isPending }
        requests.append(request)
        lock.unlock()
        return request
    }

    func cancelBounded() {
        lock.lock()
        let bounded = requests.filter { $0.hasTimeout }
        if !bounded.isEmpty { currentGeneration = UUID() }
        lock.unlock()
        bounded.forEach { $0.finish(success: false) }
    }

    func takePending() -> [PlaybackStartRequest] {
        lock.lock()
        defer { lock.unlock() }
        let pending = requests
        requests = []
        return pending
    }

    func cancel() {
        lock.lock()
        currentGeneration = UUID()
        let pending = requests
        requests = []
        lock.unlock()
        pending.forEach { $0.finish(success: false) }
    }
}

/// Receiver acknowledgement and playback of the requested episode are both required.
/// Cast delivers these events on the main thread, in either order.
final class RemotePlaybackStart {
    let request: PlaybackStartRequest
    private let episodeUuid: String
    private var acknowledged = false
    private var playingRequestedEpisode = false

    init(episodeUuid: String, request: PlaybackStartRequest) {
        self.episodeUuid = episodeUuid
        self.request = request
    }

    func acknowledge() {
        acknowledged = true
        resolveIfPlaying()
    }

    func update(episodeUuid: String?, playing: Bool, failed: Bool) {
        guard episodeUuid == self.episodeUuid else {
            playingRequestedEpisode = false
            return
        }
        if failed {
            request.finish(success: false)
            return
        }
        playingRequestedEpisode = playing
        resolveIfPlaying()
    }

    private func resolveIfPlaying() {
        if acknowledged, playingRequestedEpisode { request.finish(success: true) }
    }
}

/// Explicit context for an App Intent or widget operation. Ordinary UI playback has no deadline.
final class BackgroundPlayback: @unchecked Sendable {
    @TaskLocal static var current: BackgroundPlayback?
    private let deadline: TimeInterval
    private let lock = NSLock()
    private var cancelled = false
    private var cancellationHandlers: [() -> Void] = []

    init(timeout: TimeInterval = PlaybackStartRequest.startupTimeout) {
        deadline = ProcessInfo.processInfo.systemUptime + timeout
    }

    static var canContinue: Bool {
        !Task.isCancelled && current?.isCancelled != true && (current.map { $0.remainingTime > 0 } ?? true)
    }

    var remainingTime: TimeInterval { max(0, deadline - ProcessInfo.processInfo.systemUptime) }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func onCancel(_ handler: @escaping () -> Void) {
        lock.lock()
        if cancelled {
            lock.unlock()
            handler()
        } else {
            cancellationHandlers.append(handler)
            lock.unlock()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let handlers = cancellationHandlers
        cancellationHandlers = []
        lock.unlock()
        handlers.forEach { $0() }
    }

    /// Starts main-actor work from a callback while preserving the background playback
    /// context that was active when the callback-based operation began.
    static func performOnMainActor(
        in context: BackgroundPlayback?,
        _ operation: @escaping @MainActor () -> Void
    ) {
        Task { @MainActor in
            $current.withValue(context) {
                operation()
            }
        }
    }

    @MainActor
    static func run<T>(_ operation: () async -> T) async -> T {
        if current != nil { return await operation() }
        let context = BackgroundPlayback()
        return await withTaskCancellationHandler {
            await $current.withValue(context) { await operation() }
        } onCancel: {
            context.cancel()
        }
    }
}
