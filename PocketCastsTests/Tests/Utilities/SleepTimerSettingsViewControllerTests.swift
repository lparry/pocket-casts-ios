import UIKit
import XCTest
@testable import PocketCastsUtils
@testable import podcasts

final class SleepTimerSettingsViewControllerTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var preferences: SleepTimerManager.Preferences!
    private let flags = FeatureFlagMock()

    override func setUp() {
        super.setUp()
        flags.set(.sleepTimerTimeOfDay, value: true)
        suiteName = "SleepTimerSettingsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        preferences = .init(userDefaults: defaults)
        preferences.mode = .off
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        flags.reset()
        super.tearDown()
    }

    @MainActor
    func testTimerSectionIsOnlyShownForTimeOfDay() {
        let controller = SleepTimerSettingsViewController(preferences: preferences)
        controller.loadViewIfNeeded()
        controller.tableView(controller.tableView, didSelectRowAt: IndexPath(row: 2, section: 0))
        XCTAssertEqual(controller.numberOfSections(in: controller.tableView), 3)
        XCTAssertEqual(controller.tableView(controller.tableView, titleForHeaderInSection: 2), L10n.sleepTimer)
        controller.tableView(controller.tableView, didSelectRowAt: IndexPath(row: 1, section: 0))
        XCTAssertEqual(controller.numberOfSections(in: controller.tableView), 1)
        controller.tableView(controller.tableView, didSelectRowAt: IndexPath(row: 0, section: 0))
        XCTAssertEqual(controller.numberOfSections(in: controller.tableView), 1)
        XCTAssertEqual(preferences.mode, .off)
    }

    @MainActor
    func testChoosingModeSavesImmediately() {
        let controller = SleepTimerSettingsViewController(preferences: preferences)
        controller.loadViewIfNeeded()
        XCTAssertNil(controller.customRightBtn)
        controller.tableView(controller.tableView, didSelectRowAt: IndexPath(row: 2, section: 0))
        XCTAssertEqual(preferences.mode, .timeWindow)
        XCTAssertEqual(preferences.automaticTimer.duration, 10.minutes)
    }

    @MainActor
    func testStopAfterFollowsDurationAndSavesImmediately() throws {
        preferences.mode = .timeWindow
        preferences.lastSetting = .init(duration: 5.minutes, sleepOnEpisodeEnd: nil)
        let controller = SleepTimerSettingsViewController(preferences: preferences)
        controller.loadViewIfNeeded()
        XCTAssertEqual(controller.tableView(controller.tableView, numberOfRowsInSection: 2), 3)
        let durationCell = controller.tableView(controller.tableView, cellForRowAt: IndexPath(row: 0, section: 2))
        XCTAssertEqual(durationCell.accessoryType, .checkmark)
        let endOfEpisodeCell = controller.tableView(controller.tableView, cellForRowAt: IndexPath(row: 2, section: 2))
        XCTAssertEqual(endOfEpisodeCell.textLabel?.text, L10n.sleepTimerEndOfEpisode)

        let stepperCell = try XCTUnwrap(controller.tableView(controller.tableView, cellForRowAt: IndexPath(row: 1, section: 2)) as? TimeStepperCell)
        XCTAssertEqual(stepperCell.timeStepper.currentValue, 10.minutes)
        stepperCell.timeStepper.currentValue = 45.minutes
        stepperCell.timeStepper.sendActions(for: .valueChanged)
        XCTAssertEqual(preferences.automaticTimer.duration, 45.minutes)
        XCTAssertEqual(preferences.lastSetting?.duration, 5.minutes)
    }

    @MainActor
    func testEndOfEpisodeCanBeChosenAndSwitchedBackToDuration() throws {
        preferences.mode = .timeWindow
        preferences.automaticTimer = .init(duration: 20.minutes, sleepOnEpisodeEnd: nil)
        let controller = SleepTimerSettingsViewController(preferences: preferences)
        controller.loadViewIfNeeded()

        controller.tableView(controller.tableView, didSelectRowAt: IndexPath(row: 2, section: 2))
        XCTAssertEqual(controller.tableView(controller.tableView, numberOfRowsInSection: 2), 2)
        let endOfEpisodeCell = controller.tableView(controller.tableView, cellForRowAt: IndexPath(row: 1, section: 2))
        XCTAssertEqual(endOfEpisodeCell.accessoryType, .checkmark)
        XCTAssertTrue(endOfEpisodeCell.accessibilityTraits.contains(.selected))
        XCTAssertNil(preferences.automaticTimer.duration)
        XCTAssertEqual(preferences.automaticTimer.sleepOnEpisodeEnd, true)
        XCTAssertEqual(preferences.automaticTimer.numberOfEpisodes, 1)

        // Switching back keeps the length chosen before End of Episode.
        controller.tableView(controller.tableView, didSelectRowAt: IndexPath(row: 0, section: 2))
        XCTAssertEqual(controller.tableView(controller.tableView, numberOfRowsInSection: 2), 3)
        XCTAssertEqual(preferences.automaticTimer.duration, 20.minutes)
    }

    @MainActor
    func testEqualTimesShowErrorAndKeepSavedWindow() throws {
        preferences.mode = .timeWindow
        let originalWindow = preferences.timeWindow
        let controller = SleepTimerSettingsViewController(preferences: preferences)
        controller.loadViewIfNeeded()
        let startCell = controller.tableView(controller.tableView, cellForRowAt: IndexPath(row: 0, section: 1))
        let endCell = controller.tableView(controller.tableView, cellForRowAt: IndexPath(row: 1, section: 1))
        let startPicker = try XCTUnwrap(datePicker(in: startCell))
        let endPicker = try XCTUnwrap(datePicker(in: endCell))
        endPicker.date = startPicker.date
        endPicker.sendActions(for: .valueChanged)
        XCTAssertEqual(controller.tableView(controller.tableView, titleForFooterInSection: 1), L10n.sleepTimerAutomaticInvalidWindow)
        XCTAssertEqual(preferences.timeWindow, originalWindow)
        endPicker.date = Calendar.current.date(byAdding: .hour, value: 1, to: startPicker.date)!
        endPicker.sendActions(for: .valueChanged)
        XCTAssertEqual(controller.tableView(controller.tableView, titleForFooterInSection: 1), L10n.sleepTimerAutomaticWindowDescription)
        XCTAssertEqual(preferences.timeWindow.startMinute, originalWindow.startMinute)
        XCTAssertEqual(preferences.timeWindow.endMinute, 23 * 60)
    }

    @MainActor
    func testTimeOfDayDescriptionShowsChosenHours() {
        let window = SleepTimerManager.TimeWindow(startMinute: 21 * 60 + 30, endMinute: 6 * 60)
        let start = SleepTimerManager.TimeWindow.date(atMinute: window.startMinute).formatted(date: .omitted, time: .shortened)
        let end = SleepTimerManager.TimeWindow.date(atMinute: window.endMinute).formatted(date: .omitted, time: .shortened)
        XCTAssertEqual(SleepTimerManager.AutomaticMode.timeWindow.explanation(for: window), L10n.sleepTimerAutomaticTimeWindowDescription(start, end))
    }

    @MainActor
    func testEveryModeHasAccessibleSelectionAndDescription() {
        let controller = SleepTimerSettingsViewController(preferences: preferences)
        controller.loadViewIfNeeded()
        for row in SleepTimerManager.AutomaticMode.allCases.indices {
            let indexPath = IndexPath(row: row, section: 0)
            controller.tableView(controller.tableView, didSelectRowAt: indexPath)
            let cell = controller.tableView(controller.tableView, cellForRowAt: indexPath)
            XCTAssertTrue(cell.accessibilityTraits.contains(.selected))
            XCTAssertEqual(cell.accessoryType, .checkmark)
            XCTAssertFalse(cell.detailTextLabel?.text?.isEmpty ?? true)
            XCTAssertEqual(cell.textLabel?.numberOfLines, 0)
            XCTAssertEqual(cell.textLabel?.adjustsFontForContentSizeCategory, true)
        }
    }

    @MainActor
    func testTimePickersFitOnSmallPhoneAndSettingsCanBeRendered() throws {
        preferences.mode = .timeWindow
        let controller = SleepTimerSettingsViewController(preferences: preferences)
        let navigation = UINavigationController(rootViewController: controller)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let previousKeyWindow = scene?.windows.first { $0.isKeyWindow }
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 375, height: 812)
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }
        window.layoutIfNeeded()
        controller.tableView.layoutIfNeeded()

        for row in 0..<2 {
            let cell = try XCTUnwrap(controller.tableView.cellForRow(at: IndexPath(row: row, section: 1)))
            let picker = try XCTUnwrap(datePicker(in: cell))
            XCTAssertGreaterThan(picker.bounds.width, 0)
            XCTAssertTrue(cell.contentView.bounds.contains(picker.convert(picker.bounds, to: cell.contentView)))
        }

        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Automatic Sleep Timer"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func datePicker(in view: UIView) -> UIDatePicker? {
        if let picker = view as? UIDatePicker { return picker }
        return view.subviews.lazy.compactMap { self.datePicker(in: $0) }.first
    }
}
