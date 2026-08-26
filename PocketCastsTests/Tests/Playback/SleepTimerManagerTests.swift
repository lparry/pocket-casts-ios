import XCTest
@testable import podcasts
import PocketCastsUtils

final class SleepTimerManagerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Constants.UserDefaults.autoRestartSleepTimer)
        UserDefaults.standard.removeObject(forKey: Constants.UserDefaults.autoRestartSleepTimerWindow)
        UserDefaults.standard.removeObject(forKey: Constants.UserDefaults.sleepTimerFinishedDate)
        UserDefaults.standard.removeObject(forKey: Constants.UserDefaults.sleepTimerSetting)
        super.tearDown()
    }

    func testRestartsInsideConfiguredWindow() {
        var restartedDuration: TimeInterval?
        let manager = makeManager { restartedDuration = $0 }
        configureRestart(manager: manager, finishedAt: now.addingTimeInterval(-29.minutes))

        manager.restartSleepTimerIfNeeded()

        XCTAssertEqual(restartedDuration, 15.minutes)
    }

    func testRestartsAtConfiguredWindowBoundary() {
        var restartedDuration: TimeInterval?
        let manager = makeManager { restartedDuration = $0 }
        configureRestart(manager: manager, finishedAt: now.addingTimeInterval(-30.minutes))

        manager.restartSleepTimerIfNeeded()

        XCTAssertEqual(restartedDuration, 15.minutes)
    }

    func testDoesNotRestartOutsideConfiguredWindow() {
        var restartedDuration: TimeInterval?
        let manager = makeManager { restartedDuration = $0 }
        configureRestart(manager: manager, finishedAt: now.addingTimeInterval(-31.minutes))

        manager.restartSleepTimerIfNeeded()

        XCTAssertNil(restartedDuration)
    }

    func testDoesNotRestartWhenAutoRestartIsDisabled() {
        var restartedDuration: TimeInterval?
        let manager = makeManager { restartedDuration = $0 }
        configureRestart(manager: manager, finishedAt: now.addingTimeInterval(-29.minutes))
        Settings.autoRestartSleepTimer = false

        manager.restartSleepTimerIfNeeded()

        XCTAssertNil(restartedDuration)
    }

    private func makeManager(onRestart: @escaping (TimeInterval) -> Void) -> SleepTimerManager {
        SleepTimerManager(
            isSleepTimerActive: { false },
            setSleepTimerInterval: onRestart,
            currentDate: { self.now }
        )
    }

    private func configureRestart(manager: SleepTimerManager, finishedAt: Date) {
        Settings.autoRestartSleepTimer = true
        Settings.autoRestartSleepTimerWindow = 30.minutes
        Settings.sleepTimerFinishedDate = finishedAt
        manager.recordSleepTimerDuration(duration: 15.minutes, onEpisodeEnd: false)
    }
}
