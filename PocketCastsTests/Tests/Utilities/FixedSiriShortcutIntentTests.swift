import AVFoundation
import GoogleCast
import PocketCastsDataModel
import XCTest
@testable import podcasts

final class FixedSiriShortcutIntentTests: XCTestCase {
    @MainActor
    func testExtendSleepTimerUsesFiveMinutesByDefault() async throws {
        let performer = RecordingFixedSiriShortcutActionPerformer()

        try await ExtendSleepTimerIntent().perform(using: performer)

        XCTAssertEqual(performer.performedActions, [.extendSleepTimer(minutes: 5)])
    }

    @MainActor
    func testExtendSleepTimerPreservesMigratedMinutes() async throws {
        let performer = RecordingFixedSiriShortcutActionPerformer()

        try await ExtendSleepTimerIntent(minutes: 12).perform(using: performer)

        XCTAssertEqual(performer.performedActions, [.extendSleepTimer(minutes: 12)])
    }

    @MainActor
    func testExtendSleepTimerRejectsNonPositiveMinutes() async {
        let performer = RecordingFixedSiriShortcutActionPerformer()

        do {
            try await ExtendSleepTimerIntent(minutes: 0).perform(using: performer)
            XCTFail("Expected extend sleep timer to reject non-positive minutes")
        } catch {
            XCTAssertEqual(error as? ExtendSleepTimerIntentError, .invalidMinutes)
        }
        XCTAssertTrue(performer.performedActions.isEmpty)
    }

    @MainActor
    func testExtendSleepTimerRejectsMinutesAboveTheAppLimit() async {
        let performer = RecordingFixedSiriShortcutActionPerformer()

        do {
            try await ExtendSleepTimerIntent(minutes: 10_000).perform(using: performer)
            XCTFail("Expected extend sleep timer to reject minutes above the app limit")
        } catch {
            XCTAssertEqual(error as? ExtendSleepTimerIntentError, .invalidMinutes)
        }
        XCTAssertTrue(performer.performedActions.isEmpty)
    }

    @MainActor
    func testExtendSleepTimerFailsWhenThereIsNoActiveTimer() async {
        let performer = RecordingFixedSiriShortcutActionPerformer(result: .unavailable)

        do {
            try await ExtendSleepTimerIntent().perform(using: performer)
            XCTFail("Expected extend sleep timer to fail")
        } catch {
            XCTAssertEqual(error as? ExtendSleepTimerIntentError, .noActiveTimer)
        }
        XCTAssertEqual(performer.performedActions, [.extendSleepTimer(minutes: 5)])
    }

    @MainActor
    func testResumePlaybackPerformsResumeAction() async throws {
        let performer = RecordingFixedSiriShortcutActionPerformer()

        try await ResumePlaybackIntent().perform(using: performer)

        XCTAssertEqual(performer.performedActions, [.resumePlayback])
    }

    @MainActor
    func testResumePlaybackFailsWhenThereIsNoEpisodeToResume() async {
        let performer = RecordingFixedSiriShortcutActionPerformer(result: .unavailable)

        do {
            try await ResumePlaybackIntent().perform(using: performer)
            XCTFail("Expected resume playback to fail")
        } catch {
            XCTAssertEqual(error as? ResumePlaybackIntentError, .noEpisode)
        }
        XCTAssertEqual(performer.performedActions, [.resumePlayback])
    }

    @MainActor
    func testResumePlaybackReportsPlaybackFailureSeparatelyFromMissingContent() async {
        let performer = RecordingFixedSiriShortcutActionPerformer(result: .playbackFailed)

        do {
            try await ResumePlaybackIntent().perform(using: performer)
            XCTFail("Expected resume playback to report playback failure")
        } catch {
            XCTAssertEqual(error as? ResumePlaybackIntentError, .playbackFailed)
        }
        XCTAssertEqual(performer.performedActions, [.resumePlayback])
    }

    @MainActor
    func testResumePlaybackWaitsForPlaybackToStart() async {
        let playbackStarter = RecordingFixedSiriShortcutPlaybackStarter(playbackStarted: true)

        let started = await SiriShortcutsManager.shared.resumePlayback(using: playbackStarter)

        XCTAssertEqual(started, .success)
        XCTAssertEqual(playbackStarter.startPlaybackCallCount, 1)
    }

    @MainActor
    func testResumePlaybackReportsPlaybackStartupFailure() async {
        let playbackStarter = RecordingFixedSiriShortcutPlaybackStarter(playbackStarted: false)

        let started = await SiriShortcutsManager.shared.resumePlayback(using: playbackStarter)

        XCTAssertEqual(started, .playbackFailed)
        XCTAssertEqual(playbackStarter.startPlaybackCallCount, 1)
    }

    @MainActor
    func testResumePlaybackDoesNotStartWithoutACurrentEpisode() async {
        let playbackStarter = RecordingFixedSiriShortcutPlaybackStarter(hasCurrentEpisode: false)

        let started = await SiriShortcutsManager.shared.resumePlayback(using: playbackStarter)

        XCTAssertEqual(started, .unavailable)
        XCTAssertEqual(playbackStarter.startPlaybackCallCount, 0)
    }

    @MainActor
    func testPlayEpisodeReturnsSuccessAfterPlaybackStarts() async throws {
        let intent = PlayEpisodeIntent(episodeUuid: "episode-uuid")
        var playedEpisodeUUID: String?

        try await intent.perform { episodeUUID in
            playedEpisodeUUID = episodeUUID
            return true
        }

        XCTAssertEqual(playedEpisodeUUID, "episode-uuid")
    }

    @MainActor
    func testPlayEpisodeReportsPlaybackFailure() async {
        let intent = PlayEpisodeIntent(episodeUuid: "episode-uuid")

        do {
            try await intent.perform { _ in false }
            XCTFail("Expected Play Episode to report playback failure")
        } catch {
            XCTAssertEqual(error as? PlayEpisodeIntentError, .playbackFailed)
        }
    }

    func testEffectsPlayerWithoutALoadedEpisodeCompletesWithFailure() async {
        let player = EffectsPlayer()
        let failure = expectation(description: "Playback failure is reported")
        let completion = expectation(description: "Playback does not report success")
        completion.isInverted = true

        player.play(
            completion: { completion.fulfill() },
            failure: { failure.fulfill() }
        )

        await fulfillment(of: [failure, completion], timeout: 1)
    }

    @MainActor
    func testPausePlaybackPerformsPauseAction() async {
        let performer = RecordingFixedSiriShortcutActionPerformer()

        await PausePlaybackIntent().perform(using: performer)

        XCTAssertEqual(performer.performedActions, [.pausePlayback])
    }

    @MainActor
    func testPausePlaybackDoesNotChangePlaybackSourceWhenAlreadyPaused() {
        let playbackPauser = RecordingFixedSiriShortcutPlaybackPauser(isPlaying: false)
        AnalyticsPlaybackHelper.shared.currentSource = .unknown
        defer { AnalyticsPlaybackHelper.shared.currentSource = nil }

        let result = SiriShortcutsManager.shared.pausePlayback(using: playbackPauser)

        XCTAssertEqual(result, .success)
        XCTAssertEqual(AnalyticsPlaybackHelper.shared.currentSource, .unknown)
        XCTAssertEqual(playbackPauser.pauseCallCount, 1)
    }
}

@MainActor
private final class RecordingFixedSiriShortcutActionPerformer: FixedSiriShortcutActionPerforming {
    private(set) var performedActions: [FixedSiriShortcutAction] = []
    private let result: FixedSiriShortcutActionResult

    init(result: FixedSiriShortcutActionResult = .success) {
        self.result = result
    }

    func perform(_ action: FixedSiriShortcutAction) async -> FixedSiriShortcutActionResult {
        performedActions.append(action)
        return result
    }
}

@MainActor
private final class RecordingFixedSiriShortcutPlaybackStarter: FixedSiriShortcutPlaybackStarting {
    let hasCurrentEpisode: Bool
    private let playbackStarted: Bool
    private(set) var startPlaybackCallCount = 0

    init(hasCurrentEpisode: Bool = true, playbackStarted: Bool = false) {
        self.hasCurrentEpisode = hasCurrentEpisode
        self.playbackStarted = playbackStarted
    }

    func startPlayback() async -> FixedSiriShortcutActionResult {
        startPlaybackCallCount += 1
        return playbackStarted ? .success : .playbackFailed
    }
}

@MainActor
private final class RecordingFixedSiriShortcutPlaybackPauser: FixedSiriShortcutPlaybackPausing {
    let isPlaying: Bool
    private(set) var pauseCallCount = 0

    init(isPlaying: Bool) {
        self.isPlaying = isPlaying
    }

    func pause(userInitiated: Bool) {
        pauseCallCount += 1
    }
}

final class PlaybackStartupTests: XCTestCase {
    func testForegroundBufferingHasNoDeadline() {
        let player = StartupTestPlayer()
        let request = PlaybackStartRequest(completion: {}, failure: { XCTFail("Foreground buffering failed") })
        let observer = PlaybackStartObserver(player: player, request: request)
        observer.didFinishSeek(true)
        XCTAssertTrue(request.isPending)
        XCTAssertFalse(request.hasTimeout)
        player.setTimeControlStatus(.playing)
        XCTAssertFalse(request.isPending)
    }

    func testForegroundRequestSurvivesCancellationOfBackgroundDeadline() {
        let requests = PlaybackStartRequests()
        var backgroundFailed = false
        let background = requests.begin(completion: { XCTFail() }, failure: { backgroundFailed = true })
        background.startTimeout()
        let foreground = requests.begin(completion: {}, failure: { XCTFail() })
        let previousGeneration = requests.generation
        requests.cancelBounded()
        XCTAssertNotEqual(requests.generation, previousGeneration)
        XCTAssertTrue(backgroundFailed)
        XCTAssertTrue(foreground.isPending)
        XCTAssertFalse(requests.hasBoundedPending)
        foreground.finish(success: true)
    }

    @MainActor
    func testBackgroundContextIsExplicitAndRestoredAfterOperation() async {
        XCTAssertNil(BackgroundPlayback.current)
        await BackgroundPlayback.run {
            XCTAssertNotNil(BackgroundPlayback.current)
            XCTAssertGreaterThan(BackgroundPlayback.current?.remainingTime ?? 0, 0)
        }
        XCTAssertNil(BackgroundPlayback.current)
    }

    @MainActor
    func testCallbackWorkRestoresCapturedBackgroundContext() async {
        let restored = expectation(description: "context restored")
        await BackgroundPlayback.run {
            let context = BackgroundPlayback.current
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    XCTAssertNil(BackgroundPlayback.current)
                    BackgroundPlayback.performOnMainActor(in: context) {
                        XCTAssertTrue(BackgroundPlayback.current === context)
                        restored.fulfill()
                        continuation.resume()
                    }
                }
            }
        }
        await fulfillment(of: [restored], timeout: 1)
    }

    @MainActor
    func testCancelledBackgroundTaskInvokesStartupCancellation() async {
        let installed = expectation(description: "installed")
        let cancelled = expectation(description: "cancelled")
        let task = Task {
            await BackgroundPlayback.run {
                await withCheckedContinuation { continuation in
                    BackgroundPlayback.current?.onCancel {
                        cancelled.fulfill()
                        continuation.resume()
                    }
                    installed.fulfill()
                }
            }
        }
        await fulfillment(of: [installed], timeout: 1)
        task.cancel()
        await task.value
        await fulfillment(of: [cancelled], timeout: 1)
    }

    @MainActor
    func testCastSDKAbortFailsAndRemovesListener() {
        let client = StartupCastClient()
        var failures = 0
        let observer = GoogleCastStartupObserver(client: client, episodeUuid: "requested", completion: { XCTFail() }, failure: { failures += 1 })
        let command = GCKRequest.application()
        observer.send { command }
        command.abort(with: .cancelled)
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(client.listenerCount, 0)
        observer.requestDidComplete(command)
        XCTAssertEqual(failures, 1)
    }

    @MainActor
    func testCastSDKAcceptanceAloneDoesNotSucceedAndDisconnectCleansUp() {
        let client = StartupCastClient()
        var failures = 0
        let observer = GoogleCastStartupObserver(client: client, episodeUuid: "requested", completion: { XCTFail() }, failure: { failures += 1 })
        let command = GCKRequest.application()
        observer.send { command }
        command.complete()
        XCTAssertEqual(failures, 0)
        XCTAssertEqual(client.listenerCount, 1)
        observer.cancel()
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(client.listenerCount, 0)
    }

    @MainActor
    func testIndefiniteBufferingTimesOutAndRejectsLatePlayback() async {
        let failed = expectation(description: "startup timed out")
        var failures = 0
        var stopped = false
        let player = StartupTestPlayer()
        let request = PlaybackStartRequest(completion: { XCTFail("Late playback must not succeed") }, failure: {
            failures += 1
            failed.fulfill()
        })
        let observer = PlaybackStartObserver(player: player, request: request, timeout: 0.01, onTimeout: { stopped = true })
        observer.didFinishSeek(true)
        await fulfillment(of: [failed], timeout: 1)
        XCTAssertTrue(stopped)
        XCTAssertFalse(request.isPending)
        player.setTimeControlStatus(.playing)
        observer.update()
        XCTAssertEqual(failures, 1)
    }

    @MainActor
    func testCompletedStartupCancelsDeadline() async {
        let elapsed = expectation(description: "past deadline")
        let request = PlaybackStartRequest(completion: {}, failure: { XCTFail("Completed request timed out") })
        request.startTimeout(after: 0.01) { XCTFail("Completed playback was stopped") }
        request.finish(success: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { elapsed.fulfill() }
        await fulfillment(of: [elapsed], timeout: 1)
    }

    func testRemoteStartupRequiresAcknowledgementAndMatchingPlayback() {
        var succeeded = false
        let request = PlaybackStartRequest(completion: { succeeded = true }, failure: { XCTFail() })
        let start = RemotePlaybackStart(episodeUuid: "requested", request: request)
        start.acknowledge()
        start.update(episodeUuid: "old", playing: true, failed: false)
        XCTAssertFalse(succeeded)
        start.update(episodeUuid: "requested", playing: false, failed: false)
        XCTAssertFalse(succeeded)
        start.update(episodeUuid: "requested", playing: true, failed: false)
        XCTAssertTrue(succeeded)
    }

    func testRemotePlaybackBeforeAcknowledgementStillWaits() {
        var succeeded = false
        let request = PlaybackStartRequest(completion: { succeeded = true }, failure: { XCTFail() })
        let start = RemotePlaybackStart(episodeUuid: "requested", request: request)
        start.update(episodeUuid: "requested", playing: true, failed: false)
        XCTAssertFalse(succeeded)
        start.acknowledge()
        XCTAssertTrue(succeeded)
    }

    func testRemoteFailureAndDisconnectRejectLateAcknowledgement() {
        for receiverFailure in [true, false] {
            var failures = 0
            let request = PlaybackStartRequest(completion: { XCTFail() }, failure: { failures += 1 })
            let start = RemotePlaybackStart(episodeUuid: "requested", request: request)
            if receiverFailure {
                start.update(episodeUuid: "requested", playing: false, failed: true)
            } else {
                request.finish(success: false)
            }
            start.acknowledge()
            start.update(episodeUuid: "requested", playing: true, failed: false)
            XCTAssertEqual(failures, 1)
        }
    }

    @MainActor
    func testRemoteAcknowledgementWithoutPlaybackTimesOut() async {
        let failed = expectation(description: "receiver never started")
        let request = PlaybackStartRequest(completion: { XCTFail() }, failure: { failed.fulfill() })
        let start = RemotePlaybackStart(episodeUuid: "requested", request: request)
        request.startTimeout(after: 0.01)
        start.acknowledge()
        await fulfillment(of: [failed], timeout: 1)
        XCTAssertFalse(request.isPending)
    }

    func testCastRejectsUnuploadedEpisodeBeforeSendingCommand() {
        var reportedError = false
        let player = GoogleCastPlayer(reportPlaybackError: { error in
            if case .chromecastError = error { reportedError = true } else { XCTFail("Wrong UI error") }
        })
        player.loadEpisode(UserEpisode())
        var failed = false
        player.play(completion: { XCTFail() }, failure: { failed = true })
        XCTAssertTrue(failed)
        XCTAssertFalse(player.shouldBePlaying())
        XCTAssertTrue(reportedError)
    }


    func testCancellationRejectsLateSuccessExactlyOnce() {
        let starts = PlaybackStartRequests()
        var successes = 0
        var failures = 0
        let request = starts.begin(completion: { successes += 1 }, failure: { failures += 1 })
        let generation = starts.generation

        starts.cancel()
        request.finish(success: true)
        starts.cancel()

        XCTAssertFalse(request.isPending)
        XCTAssertEqual(successes, 0)
        XCTAssertEqual(failures, 1)
        XCTAssertNotEqual(starts.generation, generation)
    }

    func testCancellationDoesNotAffectLaterPlayback() {
        let starts = PlaybackStartRequests()
        let old = starts.begin(completion: { XCTFail("Cancelled playback must not succeed") }, failure: nil)
        starts.cancel()
        var succeeded = false
        let current = starts.begin(completion: { succeeded = true }, failure: nil)

        old.finish(success: true)
        XCTAssertTrue(current.isPending)
        current.finish(success: true)
        XCTAssertTrue(succeeded)
    }

    func testTransferredCallbacksSurvivePlayerCleanup() {
        let starts = PlaybackStartRequests()
        var results: [Bool] = []
        _ = starts.begin(completion: { results.append(true) }, failure: { results.append(false) })
        let transferred = starts.takePending()

        starts.cancel()
        XCTAssertTrue(results.isEmpty)
        transferred.forEach { $0.finish(success: true) }
        transferred.forEach { $0.finish(success: false) }
        XCTAssertEqual(results, [true])
    }

    func testConcurrentTerminalCallbacksCompleteOnce() {
        let completed = expectation(description: "Exactly one result")
        completed.assertForOverFulfill = true
        let request = PlaybackStartRequest(completion: { completed.fulfill() }, failure: { completed.fulfill() })

        DispatchQueue.concurrentPerform(iterations: 100) { index in
            request.finish(success: index.isMultiple(of: 2))
        }
        wait(for: [completed], timeout: 1)
    }

    func testPlaybackWaitsForInitialSeek() {
        let player = StartupTestPlayer()
        var succeeded = false
        let request = PlaybackStartRequest(completion: { succeeded = true }, failure: { XCTFail("Unexpected failure") })
        let observer = PlaybackStartObserver(player: player, request: request)

        player.setTimeControlStatus(.playing)
        XCTAssertFalse(succeeded)
        observer.didFinishSeek(true)
        XCTAssertTrue(succeeded)
    }

    func testPlaybackWaitsForBufferingAfterSeek() {
        let player = StartupTestPlayer()
        var succeeded = false
        let request = PlaybackStartRequest(completion: { succeeded = true }, failure: { XCTFail("Unexpected failure") })
        let observer = PlaybackStartObserver(player: player, request: request)

        observer.didFinishSeek(true)
        XCTAssertFalse(succeeded)
        player.setTimeControlStatus(.playing)
        XCTAssertTrue(succeeded)
    }

    func testFailedSeekDoesNotReportSuccessWhenPlaybackArrives() {
        let player = StartupTestPlayer()
        var results: [Bool] = []
        let request = PlaybackStartRequest(completion: { results.append(true) }, failure: { results.append(false) })
        let observer = PlaybackStartObserver(player: player, request: request)

        observer.didFinishSeek(false)
        player.setTimeControlStatus(.playing)
        observer.didFinishSeek(true)
        XCTAssertEqual(results, [false])
    }

    func testCancelledPlaybackIgnoresLaterAVPlayerNotification() {
        let starts = PlaybackStartRequests()
        let player = StartupTestPlayer()
        var results: [Bool] = []
        let request = starts.begin(completion: { results.append(true) }, failure: { results.append(false) })
        let observer = PlaybackStartObserver(player: player, request: request)
        observer.didFinishSeek(true)

        starts.cancel()
        player.setTimeControlStatus(.playing)
        XCTAssertEqual(results, [false])
    }

    func testStreamFailureWhileBufferingCompletesWithFailure() {
        let player = StartupTestPlayer()
        var results: [Bool] = []
        let request = PlaybackStartRequest(completion: { results.append(true) }, failure: { results.append(false) })
        let observer = PlaybackStartObserver(player: player, request: request)
        observer.didFinishSeek(true)

        player.fail()
        player.setTimeControlStatus(.playing)
        XCTAssertEqual(results, [false])
    }
}

private final class StartupTestPlayerItem: AVPlayerItem {
    override var status: AVPlayerItem.Status { .readyToPlay }
}

private final class StartupTestPlayer: AVPlayer {
    private let item = StartupTestPlayerItem(asset: AVMutableComposition())
    private var simulatedStatus: AVPlayer.TimeControlStatus = .waitingToPlayAtSpecifiedRate

    private var simulatedPlayerStatus: AVPlayer.Status = .readyToPlay

    override var status: AVPlayer.Status { simulatedPlayerStatus }
    override var currentItem: AVPlayerItem? { item }
    override var timeControlStatus: AVPlayer.TimeControlStatus { simulatedStatus }

    func fail() {
        willChangeValue(forKey: "status")
        simulatedPlayerStatus = .failed
        didChangeValue(forKey: "status")
    }

    func setTimeControlStatus(_ status: AVPlayer.TimeControlStatus) {
        willChangeValue(forKey: "timeControlStatus")
        simulatedStatus = status
        didChangeValue(forKey: "timeControlStatus")
    }
}

private final class StartupCastClient: GCKRemoteMediaClient {
    var listenerCount = 0
    override func add(_ listener: GCKRemoteMediaClientListener) { listenerCount += 1 }
    override func remove(_ listener: GCKRemoteMediaClientListener) { listenerCount -= 1 }
    override var mediaStatus: GCKMediaStatus? { nil }
}
