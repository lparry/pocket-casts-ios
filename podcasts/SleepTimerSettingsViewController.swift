import PocketCastsUtils
import UIKit

final class SleepTimerSettingsViewController: PCTableViewController {
    private enum Section { case modes, window, timer }
    private enum TimerRow { case duration, endOfEpisode, stopAfter }

    private static let timeStepperCellId = "TimeStepperCell"

    private let preferences: SleepTimerManager.Preferences
    private var mode: SleepTimerManager.AutomaticMode
    private var window: SleepTimerManager.TimeWindow
    private var timer: SleepTimerManager.SleepTimerSetting

    private var sections: [Section] {
        mode == .timeWindow ? [.modes, .window, .timer] : [.modes]
    }

    private var timerStopsAtEpisodeEnd: Bool {
        timer.duration == nil
    }

    private var timerRows: [TimerRow] {
        timerStopsAtEpisodeEnd ? [.duration, .endOfEpisode] : [.duration, .endOfEpisode, .stopAfter]
    }

    private var timerDuration: TimeInterval {
        timer.duration ?? SleepTimerManager.SleepTimerSetting.defaultAutomaticDuration
    }

    init(preferences: SleepTimerManager.Preferences = .init()) {
        self.preferences = preferences
        mode = preferences.mode
        window = preferences.timeWindow
        timer = preferences.automaticTimer
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
        customRightBtn = UIBarButtonItem(barButtonSystemItem: .save, target: self, action: #selector(save))
        updateSaveButton()
    }

    override func reloadData() {
        super.reloadData()
        updateSaveButton()
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
            let cell = textCell(title: choice.title, subtitle: choice.explanation)
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
                self.updateSaveButton()
                self.tableView.footerView(forSection: 1)?.textLabel?.text = self.windowFooter
                // Resize the validation footer without replacing the active date picker.
                self.tableView.beginUpdates()
                self.tableView.endUpdates()
            }
            return cell
        case .timer:
            switch timerRows[indexPath.row] {
            case .duration:
                return timerChoiceCell(title: L10n.sleepTimerAutomaticDuration, selected: !timerStopsAtEpisodeEnd)
            case .endOfEpisode:
                return timerChoiceCell(title: L10n.sleepTimerEndOfEpisode, selected: timerStopsAtEpisodeEnd)
            case .stopAfter:
                return stopAfterCell(tableView, indexPath: indexPath)
            }
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch sections[indexPath.section] {
        case .modes:
            mode = SleepTimerManager.AutomaticMode.allCases[indexPath.row]
            reloadData()
        case .timer:
            switch timerRows[indexPath.row] {
            case .duration:
                timer = .init(duration: timerDuration, sleepOnEpisodeEnd: nil)
            case .endOfEpisode:
                timer = .init(duration: nil, sleepOnEpisodeEnd: true, numberOfEpisodes: 1)
            case .stopAfter:
                return
            }
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
        let duration = timerDuration
        cell.cellLabel.text = title
        cell.cellSecondaryLabel.text = TimeFormatter.shared.minutesHoursFormatted(time: duration)
        cell.timeStepper.tintColor = ThemeColor.primaryInteractive01()
        cell.timeStepper.minimumValue = Constants.Limits.minSleepTime
        cell.timeStepper.maximumValue = Constants.Limits.maxSleepTime
        cell.timeStepper.currentValue = duration
        cell.configureAccessibilityLabel(text: title, time: Int(duration))
        cell.onValueChanged = { [weak self, weak cell] value in
            self?.timer = .init(duration: value, sleepOnEpisodeEnd: nil)
            cell?.cellSecondaryLabel.text = TimeFormatter.shared.minutesHoursFormatted(time: value)
            cell?.configureAccessibilityLabel(text: title, time: Int(value))
        }
        return cell
    }

    private func updateSaveButton() {
        customRightBtn?.isEnabled = mode != .timeWindow || window.isValid
    }

    @objc private func save() {
        guard mode != .timeWindow || window.isValid else { return }
        if window.isValid { preferences.timeWindow = window }
        preferences.automaticTimer = timer
        let previousMode = preferences.mode
        preferences.mode = mode
        if previousMode != mode {
            Settings.trackValueChanged(.settingsGeneralAutomaticSleepTimerChanged, value: mode.rawValue)
            if (previousMode == .afterTimerEnds) != (mode == .afterTimerEnds) {
                Settings.trackValueToggled(.settingsGeneralAutoSleepTimerRestartToggled, enabled: mode == .afterTimerEnds)
            }
        }
        navigationController?.popViewController(animated: true)
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
        picker.date = Calendar.autoupdatingCurrent.date(from: DateComponents(year: 2001, month: 1, day: 15, hour: minute / 60, minute: minute % 60)) ?? .now
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

    var explanation: String {
        switch self {
        case .off: return L10n.sleepTimerAutomaticOffDescription
        case .afterTimerEnds: return L10n.sleepTimerAutomaticAfterTimerEndsDescription
        case .timeWindow: return L10n.sleepTimerAutomaticTimeWindowDescription
        }
    }
}
