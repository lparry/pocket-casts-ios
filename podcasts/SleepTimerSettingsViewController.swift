import PocketCastsUtils
import UIKit

final class SleepTimerSettingsViewController: PCTableViewController {
    private enum Section { case modes, window, timer }
    private enum TimerRow { case duration, stopAfter, endOfEpisode }

    private static let timeStepperCellId = "TimeStepperCell"

    private let preferences: SleepTimerManager.Preferences
    private var mode: SleepTimerManager.AutomaticMode
    private var window: SleepTimerManager.TimeWindow
    private var timer: SleepTimerManager.SleepTimerSetting
    /// Kept apart from `timer` so choosing End of Episode and then Duration again restores the chosen length.
    private var duration: TimeInterval

    private var sections: [Section] {
        mode == .timeWindow ? [.modes, .window, .timer] : [.modes]
    }

    private var timerStopsAtEpisodeEnd: Bool {
        timer.duration == nil
    }

    private var timerRows: [TimerRow] {
        timerStopsAtEpisodeEnd ? [.duration, .endOfEpisode] : [.duration, .stopAfter, .endOfEpisode]
    }

    init(preferences: SleepTimerManager.Preferences = .init()) {
        self.preferences = preferences
        mode = preferences.mode
        window = preferences.timeWindow
        timer = preferences.automaticTimer
        duration = preferences.automaticTimer.duration ?? SleepTimerManager.SleepTimerSetting.defaultAutomaticDuration
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.sleepTimerAutomaticTitle
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 70
        tableView.register(UINib(nibName: Self.timeStepperCellId, bundle: nil), forCellReuseIdentifier: Self.timeStepperCellId)
        insetAdjuster.setupInsetAdjustmentsForMiniPlayer(scrollView: tableView)
    }

    func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch sections[section] {
        case .modes: return SleepTimerManager.AutomaticMode.allCases.count
        case .window: return 2
        case .timer: return timerRows.count
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch sections[indexPath.section] {
        case .modes:
            let choice = SleepTimerManager.AutomaticMode.allCases[indexPath.row]
            let cell = textCell(title: choice.title, subtitle: choice.explanation(for: window))
            cell.accessoryType = mode == choice ? .checkmark : .none
            cell.accessibilityTraits = mode == choice ? [.button, .selected] : .button
            return cell
        case .window:
            let isStart = indexPath.row == 0
            let cell = SleepTimerTimePickerCell()
            cell.configure(title: isStart ? L10n.sleepTimerAutomaticStart : L10n.sleepTimerAutomaticEnd,
                           minute: isStart ? window.startMinute : window.endMinute)
            cell.onChange = { [weak self] minute in
                guard let self else { return }
                if isStart {
                    self.window.startMinute = minute
                } else {
                    self.window.endMinute = minute
                }
                self.windowChanged()
            }
            return cell
        case .timer:
            switch timerRows[indexPath.row] {
            case .duration:
                return timerChoiceCell(title: L10n.sleepTimerAutomaticDuration, selected: !timerStopsAtEpisodeEnd)
            case .stopAfter:
                return stopAfterCell(tableView, indexPath: indexPath)
            case .endOfEpisode:
                return timerChoiceCell(title: L10n.sleepTimerEndOfEpisode, selected: timerStopsAtEpisodeEnd)
            }
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch sections[indexPath.section] {
        case .modes:
            select(SleepTimerManager.AutomaticMode.allCases[indexPath.row])
        case .timer:
            switch timerRows[indexPath.row] {
            case .duration:
                timer = .init(duration: duration, sleepOnEpisodeEnd: nil)
            case .stopAfter:
                return
            case .endOfEpisode:
                timer = .init(duration: nil, sleepOnEpisodeEnd: true, numberOfEpisodes: 1)
            }
            preferences.automaticTimer = timer
            reloadData()
        case .window:
            break
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch sections[section] {
        case .modes: return nil
        case .window: return L10n.sleepTimerAutomaticEveryDay
        case .timer: return L10n.sleepTimer
        }
    }

    private var windowFooter: String {
        window.isValid ? L10n.sleepTimerAutomaticWindowDescription : L10n.sleepTimerAutomaticInvalidWindow
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        sections[section] == .window ? windowFooter : nil
    }

    private func textCell(title: String, subtitle: String? = nil) -> ThemeableCell {
        let cell = ThemeableCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = title
        cell.textLabel?.font = UIFont.preferredFont(forTextStyle: .body)
        cell.textLabel?.adjustsFontForContentSizeCategory = true
        cell.textLabel?.numberOfLines = 0
        cell.textLabel?.textAlignment = .natural
        cell.detailTextLabel?.text = subtitle
        cell.detailTextLabel?.font = UIFont.preferredFont(forTextStyle: .footnote)
        cell.detailTextLabel?.adjustsFontForContentSizeCategory = true
        cell.detailTextLabel?.numberOfLines = 0
        cell.detailTextLabel?.textAlignment = .natural
        cell.textLabel?.textColor = ThemeColor.primaryText01()
        cell.detailTextLabel?.textColor = ThemeColor.primaryText02()
        return cell
    }

    private func timerChoiceCell(title: String, selected: Bool) -> ThemeableCell {
        let cell = textCell(title: title)
        cell.accessoryType = selected ? .checkmark : .none
        cell.accessibilityTraits = selected ? [.button, .selected] : .button
        return cell
    }

    private func stopAfterCell(_ tableView: UITableView, indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.timeStepperCellId, for: indexPath) as! TimeStepperCell
        let title = L10n.sleepTimerAutomaticStopAfter
        cell.cellLabel.text = title
        cell.cellSecondaryLabel.text = TimeFormatter.shared.minutesHoursFormatted(time: duration)
        cell.timeStepper.tintColor = ThemeColor.primaryInteractive01()
        cell.timeStepper.minimumValue = Constants.Limits.minSleepTime
        cell.timeStepper.maximumValue = Constants.Limits.maxSleepTime
        cell.timeStepper.currentValue = duration
        cell.configureAccessibilityLabel(text: title, time: Int(duration))
        cell.onValueChanged = { [weak self, weak cell] value in
            guard let self else { return }
            self.duration = value
            self.timer = .init(duration: value, sleepOnEpisodeEnd: nil)
            self.preferences.automaticTimer = self.timer
            cell?.cellSecondaryLabel.text = TimeFormatter.shared.minutesHoursFormatted(time: value)
            cell?.configureAccessibilityLabel(text: title, time: Int(value))
        }
        return cell
    }

    private func select(_ newMode: SleepTimerManager.AutomaticMode) {
        guard newMode != mode else { return }
        let previousMode = mode
        mode = newMode
        preferences.mode = newMode
        Settings.trackValueChanged(.settingsGeneralAutomaticSleepTimerChanged, value: newMode)
        if (previousMode == .afterTimerEnds) != (newMode == .afterTimerEnds) {
            Settings.trackValueToggled(.settingsGeneralAutoSleepTimerRestartToggled, enabled: newMode == .afterTimerEnds)
        }
        reloadData()
    }

    private func windowChanged() {
        // An invalid window isn't saved, so the last valid one stays in effect until the times differ again.
        preferences.timeWindow = window
        if let section = sections.firstIndex(of: .window) {
            tableView.footerView(forSection: section)?.textLabel?.text = windowFooter
        }
        // Refresh the Time of Day hours and resize the footer without replacing the active date picker.
        let timeOfDayRow = IndexPath(row: SleepTimerManager.AutomaticMode.allCases.firstIndex(of: .timeWindow) ?? 0, section: 0)
        tableView.performBatchUpdates {
            self.tableView.reloadRows(at: [timeOfDayRow], with: .none)
        }
    }

    override func handleThemeChanged() { tableView.reloadData() }
}

private final class SleepTimerTimePickerCell: ThemeableCell {
    private let label = ThemeableLabel()
    private let picker = UIDatePicker()
    var onChange: ((Int) -> Void)?

    init() {
        super.init(style: .default, reuseIdentifier: nil)
        selectionStyle = .none
        label.font = UIFont.preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        picker.datePickerMode = .time
        picker.preferredDatePickerStyle = .compact
        picker.calendar = .autoupdatingCurrent
        picker.timeZone = .autoupdatingCurrent
        picker.addTarget(self, action: #selector(timeChanged), for: .valueChanged)
        let stack = UIStackView(arrangedSubviews: [label, picker])
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
        ])
        handleThemeDidChange()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, minute: Int) {
        label.text = title
        picker.accessibilityLabel = title
        picker.date = SleepTimerManager.TimeWindow.date(atMinute: minute)
    }

    @objc private func timeChanged() {
        let components = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: picker.date)
        guard let hour = components.hour, let minute = components.minute else { return }
        onChange?(hour * 60 + minute)
    }

    override func handleThemeDidChange() {
        picker.overrideUserInterfaceStyle = Theme.isDarkTheme ? .dark : .light
    }
}

extension SleepTimerManager.AutomaticMode {
    var title: String {
        switch self {
        case .off: return L10n.sleepTimerAutomaticOff
        case .afterTimerEnds: return L10n.sleepTimerAutomaticAfterTimerEnds
        case .timeWindow: return L10n.sleepTimerAutomaticTimeWindow
        }
    }

    func explanation(for window: SleepTimerManager.TimeWindow) -> String {
        switch self {
        case .off: return L10n.sleepTimerAutomaticOffDescription
        case .afterTimerEnds: return L10n.sleepTimerAutomaticAfterTimerEndsDescription
        case .timeWindow:
            return L10n.sleepTimerAutomaticTimeWindowDescription(Self.formattedTime(atMinute: window.startMinute),
                                                                 Self.formattedTime(atMinute: window.endMinute))
        }
    }

    private static func formattedTime(atMinute minute: Int) -> String {
        SleepTimerManager.TimeWindow.date(atMinute: minute).formatted(date: .omitted, time: .shortened)
    }
}

extension SleepTimerManager.TimeWindow {
    /// A date on a fixed day at `minute` past local midnight, for showing or picking a time of day.
    static func date(atMinute minute: Int) -> Date {
        Calendar.autoupdatingCurrent.date(from: DateComponents(year: 2001, month: 1, day: 15, hour: minute / 60, minute: minute % 60)) ?? .now
    }
}
