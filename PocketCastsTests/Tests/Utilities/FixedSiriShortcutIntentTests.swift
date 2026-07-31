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
        let performer = RecordingFixedSiriShortcutActionPerformer(actionSucceeded: false)

        do {
            try await ExtendSleepTimerIntent().perform(using: performer)
            XCTFail("Expected extend sleep timer to fail")
        } catch {
            XCTAssertEqual(error as? ExtendSleepTimerIntentError, .noActiveTimer)
        }
        XCTAssertEqual(performer.performedActions, [.extendSleepTimer(minutes: 5)])
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
