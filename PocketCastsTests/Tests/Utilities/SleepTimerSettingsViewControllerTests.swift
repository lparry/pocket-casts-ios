import UIKit
import XCTest
@testable import podcasts

final class SleepTimerSettingsViewControllerTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var preferences: SleepTimerManager.Preferences!

    override func setUp() {
        super.setUp()
        suiteName = "SleepTimerSettingsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        preferences = .init(userDefaults: defaults)
        preferences.mode = .off
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    @MainActor
    func testTimerSectionIsOnlyShownForTimeOfDay() {
        let controller = SleepTimerSettingsViewController(preferences: preferences)
        controller.loadViewIfNeeded()
        controller.tableView(controller.tableView, didSelectRowAt: IndexPath(row: 2, section: 0))
        XCTAssertEqual(controller.numberOfSections(in: controller.tableView), 3)
        XCTAssertEqual(controller.tableView(controller.tableView, titleForHeaderInSection: 2), L10n.sleepTimer)
        XCTAssertEqual(controller.customRightBtn?.isEnabled, true)
        controller.tableView(controller.tableView, didSelectRowAt: IndexPath(row: 1, section: 0))
        XCTAssertEqual(controller.numberOfSections(in: controller.tableView), 1)
        controller.tableView(controller.tableView, didSelectRowAt: IndexPath(row: 0, section: 0))
        XCTAssertEqual(controller.numberOfSections(in: controller.tableView), 1)
        XCTAssertEqual(preferences.mode, .off)
    }

    @MainActor
    func testModeIsSavedOnlyAfterSaveIsTapped() throws {
        let controller = SleepTimerSettingsViewController(preferences: preferences)
        controller.loadViewIfNeeded()
        controller.tableView(controller.tableView, didSelectRowAt: IndexPath(row: 2, section: 0))
        XCTAssertEqual(preferences.mode, .off)
        XCTAssertEqual(controller.customRightBtn?.isEnabled, true)
        let action = try XCTUnwrap(controller.customRightBtn?.action)
        controller.perform(action)
        XCTAssertEqual(preferences.mode, .timeWindow)
        XCTAssertEqual(preferences.automaticTimer.duration, 10.minutes)
    }

    @MainActor
    func testChosenDurationIsSavedOnlyAfterSaveIsTapped() throws {
        preferences.mode = .timeWindow
        preferences.lastSetting = .init(duration: 5.minutes, sleepOnEpisodeEnd: nil)
        let controller = SleepTimerSettingsViewController(preferences: preferences)
        controller.loadViewIfNeeded()
        XCTAssertEqual(controller.tableView(controller.tableView, numberOfRowsInSection: 2), 3)
        let durationCell = controller.tableView(controller.tableView, cellForRowAt: IndexPath(row: 0, section: 2))
        XCTAssertEqual(durationCell.accessoryType, .checkmark)

        let stepperCell = try XCTUnwrap(controller.tableView(controller.tableView, cellForRowAt: IndexPath(row: 2, section: 2)) as? TimeStepperCell)
        XCTAssertEqual(stepperCell.timeStepper.currentValue, 10.minutes)
        stepperCell.timeStepper.currentValue = 45.minutes
        stepperCell.timeStepper.sendActions(for: .valueChanged)
        XCTAssertEqual(preferences.automaticTimer.duration, 10.minutes)

        controller.perform(try XCTUnwrap(controller.customRightBtn?.action))
        XCTAssertEqual(preferences.automaticTimer.duration, 45.minutes)
        XCTAssertEqual(preferences.lastSetting?.duration, 5.minutes)
    }

    @MainActor
    func testEndOfEpisodeCanBeChosenAndSwitchedBackToDuration() throws {
        preferences.mode = .timeWindow
        preferences.automaticTimer = .init(duration: 20.minutes, sleepOnEpisodeEnd: nil)
        let controller = SleepTimerSettingsViewController(preferences: preferences)
        controller.loadViewIfNeeded()

        controller.tableView(controller.tableView, didSelectRowAt: IndexPath(row: 1, section: 2))
        XCTAssertEqual(controller.tableView(controller.tableView, numberOfRowsInSection: 2), 2)
        let endOfEpisodeCell = controller.tableView(controller.tableView, cellForRowAt: IndexPath(row: 1, section: 2))
        XCTAssertEqual(endOfEpisodeCell.accessoryType, .checkmark)
        XCTAssertTrue(endOfEpisodeCell.accessibilityTraits.contains(.selected))
        controller.perform(try XCTUnwrap(controller.customRightBtn?.action))
        XCTAssertNil(preferences.automaticTimer.duration)
        XCTAssertEqual(preferences.automaticTimer.sleepOnEpisodeEnd, true)
        XCTAssertEqual(preferences.automaticTimer.numberOfEpisodes, 1)

        let reopened = SleepTimerSettingsViewController(preferences: preferences)
        reopened.loadViewIfNeeded()
        reopened.tableView(reopened.tableView, didSelectRowAt: IndexPath(row: 0, section: 2))
        XCTAssertEqual(reopened.tableView(reopened.tableView, numberOfRowsInSection: 2), 3)
        reopened.perform(try XCTUnwrap(reopened.customRightBtn?.action))
        XCTAssertEqual(preferences.automaticTimer.duration, 10.minutes)
    }

    @MainActor
    func testEqualTimesDisableSaveAndDoNotReplaceSavedWindow() throws {
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
        XCTAssertEqual(controller.customRightBtn?.isEnabled, false)
        XCTAssertEqual(controller.tableView(controller.tableView, titleForFooterInSection: 1), L10n.sleepTimerAutomaticInvalidWindow)
        controller.perform(try XCTUnwrap(controller.customRightBtn?.action))
        XCTAssertEqual(preferences.timeWindow, originalWindow)
        endPicker.date = Calendar.current.date(byAdding: .hour, value: 1, to: startPicker.date)!
        endPicker.sendActions(for: .valueChanged)
        XCTAssertEqual(controller.customRightBtn?.isEnabled, true)
        controller.perform(try XCTUnwrap(controller.customRightBtn?.action))
        XCTAssertEqual(preferences.timeWindow.startMinute, originalWindow.startMinute)
        XCTAssertEqual(preferences.timeWindow.endMinute, 23 * 60)
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
