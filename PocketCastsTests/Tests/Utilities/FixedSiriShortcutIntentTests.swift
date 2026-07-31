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
}

@MainActor
private final class RecordingFixedSiriShortcutActionPerformer: FixedSiriShortcutActionPerforming {
    private(set) var performedActions: [FixedSiriShortcutAction] = []

    func perform(_ action: FixedSiriShortcutAction) {
        performedActions.append(action)
    }
}
