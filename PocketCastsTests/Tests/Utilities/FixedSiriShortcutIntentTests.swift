import XCTest
@testable import podcasts

final class FixedSiriShortcutIntentTests: XCTestCase {
    @MainActor
    func testExtendSleepTimerUsesFiveMinutesByDefault() {
        let performer = RecordingFixedSiriShortcutActionPerformer()

        ExtendSleepTimerIntent().perform(using: performer)

        XCTAssertEqual(performer.performedActions, [.extendSleepTimer(minutes: 5)])
    }

    @MainActor
    func testExtendSleepTimerPreservesMigratedMinutes() {
        let performer = RecordingFixedSiriShortcutActionPerformer()

        ExtendSleepTimerIntent(minutes: 12).perform(using: performer)

        XCTAssertEqual(performer.performedActions, [.extendSleepTimer(minutes: 12)])
    }

    @MainActor
    func testExtendSleepTimerUsesFiveMinutesForInvalidMigratedValue() {
        let performer = RecordingFixedSiriShortcutActionPerformer()

        ExtendSleepTimerIntent(minutes: 0).perform(using: performer)

        XCTAssertEqual(performer.performedActions, [.extendSleepTimer(minutes: 5)])
    }

    @MainActor
    func testResumePlaybackPerformsResumeAction() throws {
        let performer = RecordingFixedSiriShortcutActionPerformer()

        try ResumePlaybackIntent().perform(using: performer)

        XCTAssertEqual(performer.performedActions, [.resumePlayback])
    }

    @MainActor
    func testResumePlaybackFailsWhenThereIsNoEpisodeToResume() {
        let performer = RecordingFixedSiriShortcutActionPerformer(actionSucceeded: false)

        XCTAssertThrowsError(try ResumePlaybackIntent().perform(using: performer)) { error in
            XCTAssertEqual(error as? ResumePlaybackIntentError, .noEpisode)
        }
        XCTAssertEqual(performer.performedActions, [.resumePlayback])
    }

    @MainActor
    func testPausePlaybackPerformsPauseAction() {
        let performer = RecordingFixedSiriShortcutActionPerformer()

        PausePlaybackIntent().perform(using: performer)

        XCTAssertEqual(performer.performedActions, [.pausePlayback])
    }
}

@MainActor
private final class RecordingFixedSiriShortcutActionPerformer: FixedSiriShortcutActionPerforming {
    private(set) var performedActions: [FixedSiriShortcutAction] = []
    private let actionSucceeded: Bool

    init(actionSucceeded: Bool = true) {
        self.actionSucceeded = actionSucceeded
    }

    func perform(_ action: FixedSiriShortcutAction) -> Bool {
        performedActions.append(action)
        return actionSucceeded
    }
}
