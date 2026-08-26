import Foundation
import PocketCastsUtils
import AVKit

class SleepTimerManager {
    private let backgroundShakeObserver: BackgroundShakeObserver
    private let isSleepTimerActive: () -> Bool
    private let setSleepTimerInterval: (TimeInterval) -> Void
    private let currentDate: () -> Date

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

    init(
        backgroundShakeObserver: BackgroundShakeObserver = BackgroundShakeObserver(),
        isSleepTimerActive: @escaping () -> Bool = { PlaybackManager.shared.sleepTimerActive() },
        setSleepTimerInterval: @escaping (TimeInterval) -> Void = { PlaybackManager.shared.setSleepTimerInterval($0) },
        currentDate: @escaping () -> Date = { .now }
    ) {
        self.backgroundShakeObserver = backgroundShakeObserver
        self.isSleepTimerActive = isSleepTimerActive
        self.setSleepTimerInterval = setSleepTimerInterval
        self.currentDate = currentDate
        backgroundShakeObserver.whenShook = { [weak self] in
            self?.restartSleepTimerAndPlayTone()
        }
    }

    func recordSleepTimerFinished() {
        Settings.sleepTimerFinishedDate = .now
        FileLog.shared.addMessage("Sleep Timer: finished (\(Settings.sleepTimerFinishedDate?.description ?? ""))")
    }

    func recordSleepTimerDuration(duration: TimeInterval?, onEpisodeEnd: Bool?) {
        let setting = SleepTimerSetting(duration: duration, sleepOnEpisodeEnd: onEpisodeEnd)
        Settings.sleepTimerLastSetting = setting
    }

    func cancelSleepTimer(userInitiated: Bool) {
        guard userInitiated else {
            return
        }

        Settings.sleepTimerFinishedDate = .distantPast
    }

    func restartSleepTimerIfNeeded() {
        guard !isSleepTimerActive(), Settings.autoRestartSleepTimer else {
            return
        }

        let now = currentDate()
        let restartWindow = Settings.autoRestartSleepTimerWindow
        if let sleepTimerFinishedDate = Settings.sleepTimerFinishedDate,
           now.timeIntervalSince(sleepTimerFinishedDate) <= restartWindow,
           let setting = Settings.sleepTimerLastSetting {
            if let duration = setting.duration {
                setSleepTimerInterval(duration)
                Analytics.track(.playerSleepTimerRestarted, properties: ["time": duration])
                FileLog.shared.addMessage("Sleep Timer: restarting it automatically (\(now.description) - \(sleepTimerFinishedDate.description) <= \(restartWindow) seconds)")
            } else if setting.sleepOnEpisodeEnd == true {
                observePlaybackEndAndReactivateTime()
            }
        }
    }

    func restartSleepTimer() {
        if let setting = Settings.sleepTimerLastSetting {
            if let duration = setting.duration {
                setSleepTimerInterval(duration)
                Analytics.track(.playerSleepTimerRestarted, properties: ["time": duration, "reason": "device_shake"])
                FileLog.shared.addMessage("Sleep Timer: restarting it after device shake")
            }
        }
    }

    func performFadeOut(player: PlaybackProtocol) {
        fadeOutManager.player = player
        fadeOutManager.fadeOut(duration: sleepTimerFadeDuration)
    }

    private func observePlaybackEndAndReactivateTime() {
        NotificationCenter.default.addObserver(self, selector: #selector(episodeDurationChanged), name: Constants.Notifications.episodeDurationChanged, object: nil)
    }

    @objc private func episodeDurationChanged() {
        let numberOfEpisodes = Settings.sleepTimerNumberOfEpisodes
        FileLog.shared.addMessage("Sleep Timer: restarting it automatically to the end of the episode")
        Analytics.track(.playerSleepTimerRestarted, properties: ["time": "end_of_episode", "number_of_episodes": numberOfEpisodes])
        PlaybackManager.shared.numberOfEpisodesToSleepAfter = numberOfEpisodes
        NotificationCenter.default.removeObserver(self, name: Constants.Notifications.episodeDurationChanged, object: nil)
    }

    private func restartSleepTimerAndPlayTone() {
        guard isSleepTimerActive() && Settings.shakeToRestartSleepTimer else {
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
    }
}
