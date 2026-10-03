import Foundation
import PocketCastsUtils
import AVFoundation
import AVKit

protocol SleepTimerPlayback {
    func sleepTimerActive() -> Bool
    func setSleepTimerInterval(_ stopIn: TimeInterval)
    func setSleepTimerEpisodeCount(_ count: Int)
}

class SleepTimerManager {
    private let restartSleepTimerIfPlayingAgainWithin: TimeInterval = 5.minutes

    private let backgroundShakeObserver: BackgroundShakeObserver
    private let preferences: Preferences
    private let playback: () -> SleepTimerPlayback
    private let now: () -> Date
    private let calendar: () -> Calendar
    private var cancelledForCurrentSession = false

    private lazy var tonePlayer: AVAudioPlayer? = {
        guard let url = Bundle.main.url(forResource: "sleep-timer-restarted-sound", withExtension: "mp3") else {
            FileLog.shared.addMessage("[Sleep Timer] Unable to create tone player because the sound file is missing from the bundle.")
            return nil
        }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            return player
        } catch {
            FileLog.shared.addMessage("[Sleep Timer] Unable to create tone player because of an exception: \(error)")
            return nil
        }
    }()

    let sleepTimerFadeDuration = 5.seconds

    private lazy var fadeOutManager = FadeOutManager()

    init(backgroundShakeObserver: BackgroundShakeObserver = BackgroundShakeObserver(),
         preferences: Preferences = Preferences(),
         playback: @escaping () -> SleepTimerPlayback = { PlaybackManager.shared },
         now: @escaping () -> Date = { .now },
         calendar: @escaping () -> Calendar = { .autoupdatingCurrent }) {
        self.backgroundShakeObserver = backgroundShakeObserver
        self.preferences = preferences
        self.playback = playback
        self.now = now
        self.calendar = calendar
        backgroundShakeObserver.whenShook = { [weak self] in
            self?.restartSleepTimerAndPlayTone()
        }
    }

    func recordSleepTimerFinished(episodeUuid: String? = nil) {
        preferences.finishedDate = now()
        preferences.finishedEpisodeUuid = episodeUuid
        FileLog.shared.addMessage("Sleep Timer: finished (\(preferences.finishedDate?.description ?? ""))")
    }

    func recordRewind(episodeUuid: String) {
        if preferences.finishedEpisodeUuid == episodeUuid {
            preferences.finishedEpisodeUuid = nil
        }
    }

    func recordSleepTimerDuration(duration: TimeInterval?, onEpisodeEnd: Bool?, numberOfEpisodes: Int? = nil) {
        let setting = SleepTimerSetting(duration: duration, sleepOnEpisodeEnd: onEpisodeEnd, numberOfEpisodes: numberOfEpisodes)
        preferences.lastSetting = setting
        preferences.finishedEpisodeUuid = nil
        cancelledForCurrentSession = false
    }

    func cancelSleepTimer(userInitiated: Bool) {
        guard userInitiated else {
            return
        }

        preferences.finishedDate = .distantPast
        cancelledForCurrentSession = true
    }

    func restartSleepTimerIfNeeded(userInitiated: Bool = true, episodeUuid: String? = nil) {
        if userInitiated {
            cancelledForCurrentSession = false
        }

        guard !playback().sleepTimerActive(), !cancelledForCurrentSession,
              let setting = preferences.lastSetting else { return }

        let currentDate = now()
        switch preferences.mode {
        case .off:
            return
        case .afterTimerEnds:
            guard let finishedDate = preferences.finishedDate else { return }
            let elapsed = currentDate.timeIntervalSince(finishedDate)
            guard elapsed >= 0, elapsed <= restartSleepTimerIfPlayingAgainWithin else { return }
        case .timeWindow:
            guard preferences.timeWindow.contains(currentDate, calendar: calendar()) else { return }
        }

        // Leave the finished episode available to rewind. Re-arming its episode timer here
        // would pause at the same ending again before the queue can advance.
        if setting.sleepOnEpisodeEnd == true, let episodeUuid, episodeUuid == preferences.finishedEpisodeUuid {
            return
        }

        activate(setting: setting, reason: preferences.mode == .timeWindow ? "time_window" : "recent_timer")
    }

    func restartSleepTimer() {
        if let setting = preferences.lastSetting {
            if let duration = setting.duration {
                playback().setSleepTimerInterval(duration)
                Analytics.track(.playerSleepTimerRestarted, properties: ["time": duration, "reason": "device_shake"])
                FileLog.shared.addMessage("Sleep Timer: restarting it after device shake")
            }
        }
    }

    func performFadeOut(player: PlaybackProtocol) {
        fadeOutManager.player = player
        fadeOutManager.fadeOut(duration: sleepTimerFadeDuration)
    }

    private func activate(setting: SleepTimerSetting, reason: String) {
        if let duration = setting.duration, duration.isFinite, duration > 0 {
            playback().setSleepTimerInterval(duration)
            Analytics.track(.playerSleepTimerRestarted, properties: ["time": duration, "reason": reason])
        } else if setting.sleepOnEpisodeEnd == true, setting.duration == nil {
            let count = setting.numberOfEpisodes ?? preferences.legacyEpisodeCount
            guard count > 0 else { return }
            playback().setSleepTimerEpisodeCount(count)
            Analytics.track(.playerSleepTimerRestarted, properties: ["time": "end_of_episode", "number_of_episodes": count, "reason": reason])
        } else {
            return
        }
        FileLog.shared.addMessage("Sleep Timer: starting automatically (\(reason))")
    }

    private func restartSleepTimerAndPlayTone() {
        guard PlaybackManager.shared.sleepTimerActive() && Settings.shakeToRestartSleepTimer else {
            backgroundShakeObserver.stopObserving()
            return
        }

        restartSleepTimer()
        playTone()
    }

    func playTone() {
        guard let tonePlayer else { return }

        tonePlayer.play()
    }

    struct SleepTimerSetting: JSONEncodable, JSONDecodable {
        let duration: TimeInterval?
        let sleepOnEpisodeEnd: Bool?
        var numberOfEpisodes: Int? = nil
    }

    enum AutomaticMode: Int, CaseIterable {
        case off
        case afterTimerEnds
        case timeWindow
    }

    struct TimeWindow: JSONEncodable, JSONDecodable, Equatable {
        var startMinute: Int
        var endMinute: Int

        static let defaultWindow = TimeWindow(startMinute: 22 * 60, endMinute: 7 * 60)

        var isValid: Bool {
            (0..<1440).contains(startMinute) && (0..<1440).contains(endMinute) && startMinute != endMinute
        }

        func contains(_ date: Date, calendar: Calendar) -> Bool {
            guard isValid else { return false }
            let components = calendar.dateComponents([.hour, .minute], from: date)
            guard let hour = components.hour, let minute = components.minute else { return false }
            let currentMinute = hour * 60 + minute
            if startMinute < endMinute {
                return currentMinute >= startMinute && currentMinute < endMinute
            }
            return currentMinute >= startMinute || currentMinute < endMinute
        }
    }

    struct Preferences {
        let userDefaults: UserDefaults

        init(userDefaults: UserDefaults = .standard) {
            self.userDefaults = userDefaults
        }

        var mode: AutomaticMode {
            get {
                if let rawValue = userDefaults.object(forKey: Constants.UserDefaults.automaticSleepTimerMode) as? Int,
                   let mode = AutomaticMode(rawValue: rawValue) {
                    return mode
                }
                let legacyEnabled = userDefaults.object(forKey: Constants.UserDefaults.autoRestartSleepTimer) as? Bool ?? true
                return legacyEnabled ? .afterTimerEnds : .off
            }
            nonmutating set {
                userDefaults.set(newValue.rawValue, forKey: Constants.UserDefaults.automaticSleepTimerMode)
            }
        }

        var timeWindow: TimeWindow {
            get {
                (try? userDefaults.jsonObject(TimeWindow.self, forKey: Constants.UserDefaults.sleepTimerTimeWindow)) ?? .defaultWindow
            }
            nonmutating set {
                guard newValue.isValid else { return }
                userDefaults.setJSONObject(newValue, forKey: Constants.UserDefaults.sleepTimerTimeWindow)
            }
        }

        var lastSetting: SleepTimerSetting? {
            get {
                try? userDefaults.jsonObject(SleepTimerSetting.self, forKey: Constants.UserDefaults.sleepTimerSetting)
            }
            nonmutating set {
                userDefaults.setJSONObject(newValue, forKey: Constants.UserDefaults.sleepTimerSetting)
            }
        }

        var finishedDate: Date? {
            get { userDefaults.object(forKey: Constants.UserDefaults.sleepTimerFinishedDate) as? Date }
            nonmutating set { userDefaults.set(newValue, forKey: Constants.UserDefaults.sleepTimerFinishedDate) }
        }

        var finishedEpisodeUuid: String? {
            get { userDefaults.string(forKey: Constants.UserDefaults.sleepTimerFinishedEpisodeUuid) }
            nonmutating set { userDefaults.set(newValue, forKey: Constants.UserDefaults.sleepTimerFinishedEpisodeUuid) }
        }

        var legacyEpisodeCount: Int {
            userDefaults.object(forKey: Constants.UserDefaults.sleepTimerNumberOfEpisodes) as? Int ?? 1
        }
    }
}
