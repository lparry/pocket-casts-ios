import XCTest
@testable import podcasts
@testable import PocketCastsServer
import PocketCastsDataModel
import PocketCastsUtils

final class SettingsTests: XCTestCase {

    private let userDefaultsSuiteName = "PocketCasts-SettingsTests"

    private lazy var defaultPlayerActions: [PlayerAction] = {
        var actions: [PlayerAction] = [
            .addBookmark,
            .markPlayed,
            .effects,
            .sleepTimer,
            .routePicker,
            .shareEpisode,
            .addToPlaylist,
            .download,
            .transcript,
            .goToPodcast,
            .starEpisode,
            .chromecast,
            .archive,
            .videoToggle
        ]
        return actions
    }()

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removePersistentDomain(forName: userDefaultsSuiteName)
    }

    func testPlayerActions() throws {
        Settings.updatePlayerActions(PlayerAction.defaultActions.filter { $0.isAvailable }) // Set defaults
        Settings.updatePlayerActions([.addBookmark, .markPlayed])

        XCTAssertEqual(defaultPlayerActions, Settings.playerActions(), "Player actions should include changes from update")
    }

    func testAutoRestartSleepTimerWindowDefaultsToFiveMinutes() {
        UserDefaults.standard.removeObject(forKey: Constants.UserDefaults.autoRestartSleepTimerWindow)
        defer { UserDefaults.standard.removeObject(forKey: Constants.UserDefaults.autoRestartSleepTimerWindow) }

        XCTAssertEqual(Settings.autoRestartSleepTimerWindow, 5.minutes)
    }

    func testAutoRestartSleepTimerWindowPersistsSelectedValue() {
        defer { UserDefaults.standard.removeObject(forKey: Constants.UserDefaults.autoRestartSleepTimerWindow) }

        Settings.autoRestartSleepTimerWindow = 2.hours

        XCTAssertEqual(Settings.autoRestartSleepTimerWindow, 2.hours)
    }

    func testAutoRestartSleepTimerWindowClampsToSupportedRange() {
        defer { UserDefaults.standard.removeObject(forKey: Constants.UserDefaults.autoRestartSleepTimerWindow) }

        Settings.autoRestartSleepTimerWindow = 1.minute
        XCTAssertEqual(Settings.autoRestartSleepTimerWindow, 5.minutes)

        Settings.autoRestartSleepTimerWindow = 3.hours
        XCTAssertEqual(Settings.autoRestartSleepTimerWindow, 2.hours)
    }
}
