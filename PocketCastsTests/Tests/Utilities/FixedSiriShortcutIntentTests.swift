import XCTest
@testable import podcasts

final class FixedSiriShortcutIntentTests: XCTestCase {
    @MainActor
    func testExtendSleepTimerUsesFiveMinutesByDefault() async {
        let performer = RecordingFixedSiriShortcutActionPerformer()

        await ExtendSleepTimerIntent().perform(using: performer)

        XCTAssertEqual(performer.performedActions, [.extendSleepTimer(minutes: 5)])
    }

    @MainActor
    func testExtendSleepTimerPreservesMigratedMinutes() async {
        let performer = RecordingFixedSiriShortcutActionPerformer()

        await ExtendSleepTimerIntent(minutes: 12).perform(using: performer)

        XCTAssertEqual(performer.performedActions, [.extendSleepTimer(minutes: 12)])
    }

    @MainActor
    func testExtendSleepTimerUsesFiveMinutesForInvalidMigratedValue() async {
        let performer = RecordingFixedSiriShortcutActionPerformer()

        await ExtendSleepTimerIntent(minutes: 0).perform(using: performer)

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
        let performer = RecordingFixedSiriShortcutActionPerformer(actionSucceeded: false)

        do {
            try await ResumePlaybackIntent().perform(using: performer)
            XCTFail("Expected resume playback to fail")
        } catch {
            XCTAssertEqual(error as? ResumePlaybackIntentError, .noEpisode)
        }
        XCTAssertEqual(performer.performedActions, [.resumePlayback])
    }

    @MainActor
    func testPausePlaybackPerformsPauseAction() async {
        let performer = RecordingFixedSiriShortcutActionPerformer()

        await PausePlaybackIntent().perform(using: performer)

        XCTAssertEqual(performer.performedActions, [.pausePlayback])
    }

    @MainActor
    func testPlayUpNextPerformsPlayUpNextAction() async throws {
        let performer = RecordingFixedSiriShortcutActionPerformer()

        try await PlayUpNextIntent().perform(using: performer)

        XCTAssertEqual(performer.performedActions, [.playUpNext])
    }

    @MainActor
    func testPlayUpNextFailsWhenThereIsNoNextEpisode() async {
        let performer = RecordingFixedSiriShortcutActionPerformer(actionSucceeded: false)

        do {
            try await PlayUpNextIntent().perform(using: performer)
            XCTFail("Expected Play Up Next to fail")
        } catch {
            XCTAssertEqual(error as? PlayUpNextIntentError, .noEpisode)
        }
        XCTAssertEqual(performer.performedActions, [.playUpNext])
    }

    @MainActor
    func testPlaySuggestedPerformsPlaySuggestedAction() async throws {
        let performer = RecordingFixedSiriShortcutActionPerformer()

        try await PlaySuggestedIntent().perform(using: performer)

        XCTAssertEqual(performer.performedActions, [.playSuggested])
    }

    @MainActor
    func testPlaySuggestedFailsWhenNoSuggestionIsAvailable() async {
        let performer = RecordingFixedSiriShortcutActionPerformer(actionSucceeded: false)

        do {
            try await PlaySuggestedIntent().perform(using: performer)
            XCTFail("Expected Play Suggested to fail")
        } catch {
            XCTAssertEqual(error as? PlaySuggestedIntentError, .unavailable)
        }
        XCTAssertEqual(performer.performedActions, [.playSuggested])
    }

    @MainActor
    func testNextChapterPerformsNextChapterAction() async {
        let performer = RecordingFixedSiriShortcutActionPerformer()

        await NextChapterIntent().perform(using: performer)

        XCTAssertEqual(performer.performedActions, [.nextChapter])
    }
}

@MainActor
private final class RecordingFixedSiriShortcutActionPerformer: FixedSiriShortcutActionPerforming {
    private(set) var performedActions: [FixedSiriShortcutAction] = []
    private let actionSucceeded: Bool

    init(actionSucceeded: Bool = true) {
        self.actionSucceeded = actionSucceeded
    }

    func perform(_ action: FixedSiriShortcutAction) async -> Bool {
        performedActions.append(action)
        return actionSucceeded
    }
}
