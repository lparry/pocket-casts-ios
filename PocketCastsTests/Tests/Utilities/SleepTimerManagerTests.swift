import XCTest
import PocketCastsUtils
@testable import podcasts

final class SleepTimerManagerTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var preferences: SleepTimerManager.Preferences!
    private var playback: PlaybackSpy!
    private var manager: SleepTimerManager!
    private var currentDate: Date!
    private var calendar: Calendar!

    override func setUp() {
        super.setUp()
        suiteName = "SleepTimerManagerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        preferences = .init(userDefaults: defaults)
        playback = PlaybackSpy()
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        currentDate = date(hour: 23)
        manager = SleepTimerManager(preferences: preferences,
                                    playback: { [unowned self] in self.playback },
                                    now: { [unowned self] in self.currentDate },
                                    calendar: { [unowned self] in self.calendar })
        preferences.mode = .timeWindow
        preferences.lastSetting = .init(duration: 30.minutes, sleepOnEpisodeEnd: nil)
    }

    override func tearDown() {
        manager = nil
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testWindowStartsSavedDurationWithoutPreviousTimerExpiry() {
        manager.restartSleepTimerIfNeeded()
        XCTAssertEqual(playback.startedDurations, [30.minutes])
    }

    func testWindowRestartsRegardlessOfHowLongAgoTimerFinished() {
        preferences.finishedDate = currentDate.addingTimeInterval(-3.hours)
        manager.restartSleepTimerIfNeeded()
        XCTAssertEqual(playback.startedDurations, [30.minutes])
    }

    func testWindowDoesNotActivateOutsideChosenHours() {
        currentDate = date(hour: 12)
        preferences.finishedDate = currentDate
        manager.restartSleepTimerIfNeeded()
        XCTAssertTrue(playback.startedDurations.isEmpty)
    }

    func testExistingTimerIsNeverResetOrDisabled() {
        playback.active = true
        manager.restartSleepTimerIfNeeded()
        currentDate = date(hour: 12)
        manager.restartSleepTimerIfNeeded()
        XCTAssertTrue(playback.startedDurations.isEmpty)
        XCTAssertTrue(playback.active)
    }

    func testRepeatedPlaybackStartsDoNotExtendTimer() {
        manager.restartSleepTimerIfNeeded()
        manager.restartSleepTimerIfNeeded()
        manager.restartSleepTimerIfNeeded(userInitiated: false)
        XCTAssertEqual(playback.startedDurations, [30.minutes])
    }

    func testExpiredTimerCanStartAgainLaterInsideWindow() {
        manager.restartSleepTimerIfNeeded()
        playback.active = false
        manager.recordSleepTimerFinished()
        currentDate = currentDate.addingTimeInterval(1.hour)
        manager.restartSleepTimerIfNeeded()
        XCTAssertEqual(playback.startedDurations, [30.minutes, 30.minutes])
    }

    func testManualCancellationSurvivesAutomaticEpisodeChangesUntilDeliberatePlay() {
        manager.cancelSleepTimer(userInitiated: true)
        manager.restartSleepTimerIfNeeded(userInitiated: false)
        manager.restartSleepTimerIfNeeded(userInitiated: false)
        XCTAssertTrue(playback.startedDurations.isEmpty)
        manager.restartSleepTimerIfNeeded(userInitiated: true)
        XCTAssertEqual(playback.startedDurations, [30.minutes])
    }

    func testInternalCancellationDoesNotSuppressAutomaticActivation() {
        manager.cancelSleepTimer(userInitiated: false)
        manager.restartSleepTimerIfNeeded(userInitiated: false)
        XCTAssertEqual(playback.startedDurations, [30.minutes])
    }

    func testChoosingAnotherTimerClearsManualCancellation() {
        manager.cancelSleepTimer(userInitiated: true)
        manager.recordSleepTimerDuration(duration: 15.minutes, onEpisodeEnd: nil)
        manager.restartSleepTimerIfNeeded(userInitiated: false)
        XCTAssertEqual(playback.startedDurations, [15.minutes])
    }

    func testOffNeverActivatesTimer() {
        preferences.mode = .off
        preferences.finishedDate = currentDate
        manager.restartSleepTimerIfNeeded()
        XCTAssertTrue(playback.startedDurations.isEmpty)
    }

    func testLegacyModeRequiresTimerToHaveFinished() {
        preferences.mode = .afterTimerEnds
        manager.restartSleepTimerIfNeeded()
        XCTAssertTrue(playback.startedDurations.isEmpty)
    }

    func testLegacyModeRestartsAtFiveMinuteBoundaryOutsideWindow() {
        preferences.mode = .afterTimerEnds
        currentDate = date(hour: 12)
        preferences.finishedDate = currentDate.addingTimeInterval(-5.minutes)
        manager.restartSleepTimerIfNeeded()
        XCTAssertEqual(playback.startedDurations, [30.minutes])
    }

    func testLegacyModeDoesNotRestartAfterFiveMinutes() {
        preferences.mode = .afterTimerEnds
        preferences.finishedDate = currentDate.addingTimeInterval(-5.minutes - 1)
        manager.restartSleepTimerIfNeeded()
        XCTAssertTrue(playback.startedDurations.isEmpty)
    }

    func testLegacyModeDoesNotRestartAfterManualCancellation() {
        preferences.mode = .afterTimerEnds
        preferences.finishedDate = currentDate
        manager.cancelSleepTimer(userInitiated: true)
        manager.restartSleepTimerIfNeeded()
        XCTAssertTrue(playback.startedDurations.isEmpty)
    }

    func testFutureExpiryDoesNotRestartLegacyTimer() {
        preferences.mode = .afterTimerEnds
        preferences.finishedDate = currentDate.addingTimeInterval(60)
        manager.restartSleepTimerIfNeeded()
        XCTAssertTrue(playback.startedDurations.isEmpty)
    }

    func testEpisodeTimerStartsImmediatelyWithOriginalChosenCount() {
        manager.recordSleepTimerDuration(duration: nil, onEpisodeEnd: true, numberOfEpisodes: 3)
        defaults.set(1, forKey: Constants.UserDefaults.sleepTimerNumberOfEpisodes)
        manager.restartSleepTimerIfNeeded()
        XCTAssertEqual(playback.startedEpisodeCounts, [3])
        XCTAssertEqual(preferences.lastSetting?.numberOfEpisodes, 3)
    }

    func testLegacyEpisodeTimerRestoresCountWithoutDurationNotification() {
        let legacyData = Data(#"{"sleepOnEpisodeEnd":true}"#.utf8)
        defaults.set(legacyData, forKey: Constants.UserDefaults.sleepTimerSetting)
        defaults.set(2, forKey: Constants.UserDefaults.sleepTimerNumberOfEpisodes)
        manager.restartSleepTimerIfNeeded()
        XCTAssertEqual(playback.startedEpisodeCounts, [2])
    }

    func testSavedDurationAndEpisodeCountSurviveReloadingPreferences() {
        manager.recordSleepTimerDuration(duration: 47.minutes, onEpisodeEnd: nil)
        XCTAssertEqual(SleepTimerManager.Preferences(userDefaults: defaults).lastSetting?.duration, 47.minutes)
        manager.recordSleepTimerDuration(duration: nil, onEpisodeEnd: true, numberOfEpisodes: 4)
        XCTAssertEqual(SleepTimerManager.Preferences(userDefaults: defaults).lastSetting?.numberOfEpisodes, 4)
    }

    func testMissingOrInvalidTimerDoesNotActivate() {
        preferences.lastSetting = nil
        manager.restartSleepTimerIfNeeded()
        preferences.lastSetting = .init(duration: -10, sleepOnEpisodeEnd: nil)
        manager.restartSleepTimerIfNeeded()
        preferences.lastSetting = .init(duration: nil, sleepOnEpisodeEnd: true, numberOfEpisodes: 0)
        manager.restartSleepTimerIfNeeded()
        XCTAssertTrue(playback.startedDurations.isEmpty)
        XCTAssertTrue(playback.startedEpisodeCounts.isEmpty)
    }

    func testMigrationPreservesLegacyDefaultsAndExplicitPreferences() {
        defaults.removeObject(forKey: Constants.UserDefaults.automaticSleepTimerMode)
        XCTAssertEqual(preferences.mode, .afterTimerEnds)
        defaults.set(false, forKey: Constants.UserDefaults.autoRestartSleepTimer)
        XCTAssertEqual(preferences.mode, .off)
        defaults.set(true, forKey: Constants.UserDefaults.autoRestartSleepTimer)
        XCTAssertEqual(preferences.mode, .afterTimerEnds)
        preferences.mode = .timeWindow
        defaults.set(false, forKey: Constants.UserDefaults.autoRestartSleepTimer)
        XCTAssertEqual(SleepTimerManager.Preferences(userDefaults: defaults).mode, .timeWindow)
    }

    func testInvalidStoredModeFallsBackToLegacyPreference() {
        defaults.set(99, forKey: Constants.UserDefaults.automaticSleepTimerMode)
        defaults.set(false, forKey: Constants.UserDefaults.autoRestartSleepTimer)
        XCTAssertEqual(preferences.mode, .off)
    }

    func testWindowPersistenceRejectsEqualAndOutOfRangeTimes() {
        let window = SleepTimerManager.TimeWindow(startMinute: 23 * 60 + 45, endMinute: 6 * 60 + 15)
        preferences.timeWindow = window
        XCTAssertEqual(SleepTimerManager.Preferences(userDefaults: defaults).timeWindow, window)
        preferences.timeWindow = .init(startMinute: 60, endMinute: 60)
        preferences.timeWindow = .init(startMinute: -1, endMinute: 60)
        preferences.timeWindow = .init(startMinute: 60, endMinute: 1440)
        XCTAssertEqual(preferences.timeWindow, window)
    }

    func testSameDayWindowIncludesStartAndExcludesEnd() {
        let window = SleepTimerManager.TimeWindow(startMinute: 10 * 60 + 15, endMinute: 14 * 60 + 30)
        XCTAssertFalse(window.contains(date(hour: 10, minute: 14), calendar: calendar))
        XCTAssertTrue(window.contains(date(hour: 10, minute: 15), calendar: calendar))
        XCTAssertTrue(window.contains(date(hour: 14, minute: 29, second: 59), calendar: calendar))
        XCTAssertFalse(window.contains(date(hour: 14, minute: 30), calendar: calendar))
    }

    func testOvernightWindowIncludesMidnightAndBothSidesOfDateChange() {
        let window = SleepTimerManager.TimeWindow.defaultWindow
        XCTAssertFalse(window.contains(date(hour: 21, minute: 59), calendar: calendar))
        XCTAssertTrue(window.contains(date(hour: 22), calendar: calendar))
        XCTAssertTrue(window.contains(date(hour: 0), calendar: calendar))
        XCTAssertTrue(window.contains(date(hour: 6, minute: 59, second: 59), calendar: calendar))
        XCTAssertFalse(window.contains(date(hour: 7), calendar: calendar))
    }

    func testMidnightStartAndEndAreHandled() {
        let startsAtMidnight = SleepTimerManager.TimeWindow(startMinute: 0, endMinute: 60)
        let endsAtMidnight = SleepTimerManager.TimeWindow(startMinute: 23 * 60, endMinute: 0)
        XCTAssertTrue(startsAtMidnight.contains(date(hour: 0), calendar: calendar))
        XCTAssertFalse(startsAtMidnight.contains(date(hour: 1), calendar: calendar))
        XCTAssertTrue(endsAtMidnight.contains(date(hour: 23), calendar: calendar))
        XCTAssertFalse(endsAtMidnight.contains(date(hour: 0), calendar: calendar))
    }

    func testWindowUsesCurrentLocalTimezone() {
        let instant = date(hour: 12)
        XCTAssertFalse(preferences.timeWindow.contains(instant, calendar: calendar))
        calendar.timeZone = TimeZone(identifier: "Australia/Melbourne")!
        XCTAssertTrue(preferences.timeWindow.contains(instant, calendar: calendar))
        currentDate = instant
        manager.restartSleepTimerIfNeeded()
        XCTAssertEqual(playback.startedDurations, [30.minutes])
    }

    func testDaylightSavingChangesUseWallClockTime() {
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let window = SleepTimerManager.TimeWindow(startMinute: 60, endMinute: 3 * 60)
        let formatter = ISO8601DateFormatter()
        for instant in ["2026-11-01T05:30:00Z", "2026-11-01T06:30:00Z", "2026-03-08T06:59:59Z"] {
            XCTAssertTrue(window.contains(formatter.date(from: instant)!, calendar: calendar))
        }
        XCTAssertFalse(window.contains(formatter.date(from: "2026-03-08T07:00:00Z")!, calendar: calendar))
    }

    func testInvalidWindowNeverActivates() {
        for window in [SleepTimerManager.TimeWindow(startMinute: 0, endMinute: 0),
                       .init(startMinute: -1, endMinute: 60),
                       .init(startMinute: 60, endMinute: 1440)] {
            XCTAssertFalse(window.isValid)
            XCTAssertFalse(window.contains(currentDate, calendar: calendar))
        }
    }

    private func date(hour: Int, minute: Int = 0, second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: hour, minute: minute, second: second))!
    }

    private final class PlaybackSpy: SleepTimerPlayback {
        var active = false
        var startedDurations: [TimeInterval] = []
        var startedEpisodeCounts: [Int] = []

        func sleepTimerActive() -> Bool { active }

        func setSleepTimerInterval(_ stopIn: TimeInterval) {
            startedDurations.append(stopIn)
            active = true
        }

        func setSleepTimerEpisodeCount(_ count: Int) {
            startedEpisodeCounts.append(count)
            active = true
        }
    }
}
