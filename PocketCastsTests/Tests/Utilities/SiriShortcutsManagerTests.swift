import Intents
import XCTest
@testable import podcasts

final class SiriShortcutsManagerTests: XCTestCase {
    func testDefaultSuggestionsDoesNotDonateLegacyShortcuts() {
        let suggestions = SiriShortcutsManager.shared.defaultSuggestions()

        XCTAssertTrue(suggestions.isEmpty)
    }

    func testAppShortcutSuggestionsPreserveTheAvailableShortcutsSection() {
        let suggestions = SiriShortcutsManager.shared.appShortcutSuggestions(isUserLoggedIn: true)

        XCTAssertEqual(suggestions.map(\.title), [
            String(localized: SetSleepTimerIntent.title),
            String(localized: ExtendSleepTimerIntent.title),
            String(localized: ResumePlaybackIntent.title),
            String(localized: PausePlaybackIntent.title),
            String(localized: PlayUpNextIntent.title),
            String(localized: PlaySuggestedIntent.title),
            String(localized: NextChapterIntent.title),
            String(localized: PreviousChapterIntent.title),
            String(localized: MarkAsPlayedIntent.title),
        ])
    }

    func testAppShortcutSuggestionsHidePlaySuggestedWhenSignedOut() {
        let suggestions = SiriShortcutsManager.shared.appShortcutSuggestions(isUserLoggedIn: false)

        XCTAssertFalse(suggestions.map(\.title).contains(String(localized: PlaySuggestedIntent.title)))
    }
}
