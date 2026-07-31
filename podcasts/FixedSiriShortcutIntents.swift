import AppIntents
import PocketCastsDataModel
import PocketCastsServer

enum FixedSiriShortcutAction: Equatable {
    case extendSleepTimer(minutes: Int)
    case resumePlayback
    case pausePlayback
    case playUpNext
    case playSuggested
}

enum FixedSiriShortcutActionResult: Equatable {
    case success
    case unavailable
    case playbackFailed
}

enum FixedSiriShortcutSuggestedEpisodePlaybackResult: Equatable {
    case success
    case notFound
    case playbackFailed
}

@MainActor
protocol FixedSiriShortcutPlaybackStarting {
    var hasCurrentEpisode: Bool { get }

    func startPlayback() async -> FixedSiriShortcutActionResult
}

extension PlaybackManager: FixedSiriShortcutPlaybackStarting {
    var hasCurrentEpisode: Bool {
        currentEpisode != nil
    }

    func startPlayback() async -> FixedSiriShortcutActionResult {
        // Keep a background App Intent alive until asynchronous audio-session and player setup finishes.
        await withCheckedContinuation { continuation in
            play(
                completion: { continuation.resume(returning: .success) },
                failure: { continuation.resume(returning: .playbackFailed) }
            )
        }
    }
}

@MainActor
protocol FixedSiriShortcutPlaybackPausing {
    var isPlaying: Bool { get }

    func pause(userInitiated: Bool)
}

extension PlaybackManager: FixedSiriShortcutPlaybackPausing {}

@MainActor
protocol FixedSiriShortcutUpNextPlaying {
    func startNextEpisode() async -> FixedSiriShortcutActionResult
}

extension PlaybackManager: FixedSiriShortcutUpNextPlaying {
    func startNextEpisode() async -> FixedSiriShortcutActionResult {
        guard let currentEpisode, queue.upNextCount() > 0 else { return .unavailable }

        return await withCheckedContinuation { continuation in
            removeIfPlayingOrQueued(
                episode: currentEpisode,
                fireNotification: true,
                userInitiated: true,
                autoPlay: true,
                completion: { continuation.resume(returning: .success) },
                failure: { continuation.resume(returning: .playbackFailed) }
            )
        }
    }
}

@MainActor
protocol FixedSiriShortcutSuggestedEpisodePlaying {
    func startSuggestedEpisode(uuid: String) async -> FixedSiriShortcutSuggestedEpisodePlaybackResult
}

extension PlaybackManager: FixedSiriShortcutSuggestedEpisodePlaying {
    func startSuggestedEpisode(uuid: String) async -> FixedSiriShortcutSuggestedEpisodePlaybackResult {
        guard BackgroundPlayback.canContinue else { return .playbackFailed }
        guard let episode = DataManager.sharedManager.findEpisode(uuid: uuid) else { return .notFound }

        AnalyticsPlaybackHelper.shared.currentSource = .siri
        return await loadAndPlay(episode: episode, overrideUpNext: false) ? .success : .playbackFailed
    }
}

@MainActor
protocol FixedSiriShortcutActionPerforming {
    @discardableResult
    func perform(_ action: FixedSiriShortcutAction) async -> FixedSiriShortcutActionResult
}

extension SiriShortcutsManager: FixedSiriShortcutActionPerforming {
    @discardableResult
    func perform(_ action: FixedSiriShortcutAction) async -> FixedSiriShortcutActionResult {
        await BackgroundPlayback.run {
            switch action {
            case let .extendSleepTimer(minutes):
                return extendSleepTimer(addTime: minutes) ? .success : .unavailable
            case .resumePlayback:
                return await resumePlayback(using: PlaybackManager.shared)
            case .pausePlayback:
                return pausePlayback(using: PlaybackManager.shared) == .success ? .success : .unavailable
            case .playUpNext:
                return await playUpNext(using: PlaybackManager.shared)
            case .playSuggested:
                return await playSuggestedAsync()
            }
        }
    }

    @MainActor
    func resumePlayback(using playbackStarter: any FixedSiriShortcutPlaybackStarting) async -> FixedSiriShortcutActionResult {
        AnalyticsHelper.siriResume()
        guard playbackStarter.hasCurrentEpisode else { return .unavailable }

        AnalyticsPlaybackHelper.shared.currentSource = analyticsSource
        return await playbackStarter.startPlayback()
    }

    @MainActor
    func playUpNext(using upNextPlayer: any FixedSiriShortcutUpNextPlaying) async -> FixedSiriShortcutActionResult {
        AnalyticsHelper.siriUpNext()
        return await upNextPlayer.startNextEpisode()
    }
}

enum ExtendSleepTimerIntentError: LocalizedError, Equatable {
    case noActiveTimer
    case invalidMinutes

    var errorDescription: String? {
        switch self {
        case .noActiveTimer:
            String(
                localized: "siri_shortcut_extend_sleep_timer_no_active_timer_error",
                defaultValue: "There’s no active sleep timer to extend.",
                table: "AppIntents"
            )
        case .invalidMinutes:
            String(
                localized: "siri_shortcut_extend_sleep_timer_invalid_minutes_error",
                defaultValue: "The number of minutes must be between 1 and 300.",
                table: "AppIntents"
            )
        }
    }
}

enum ResumePlaybackIntentError: LocalizedError, Equatable {
    case noEpisode
    case playbackFailed

    var errorDescription: String? {
        switch self {
        case .noEpisode:
            String(
                localized: "siri_shortcut_resume_playback_no_episode_error",
                defaultValue: "There’s no episode to resume.",
                table: "AppIntents"
            )
        case .playbackFailed:
            L10n.podcastDetailsPlaybackError
        }
    }
}

enum PlayUpNextIntentError: LocalizedError, Equatable {
    case noEpisode
    case playbackFailed

    var errorDescription: String? {
        switch self {
        case .noEpisode:
            String(
                localized: "siri_shortcut_play_up_next_no_episode_error",
                defaultValue: "There’s no next episode in Up Next.",
                table: "AppIntents"
            )
        case .playbackFailed:
            L10n.podcastDetailsPlaybackError
        }
    }
}

enum PlaySuggestedIntentError: LocalizedError, Equatable {
    case signInRequired
    case unavailable
    case playbackFailed

    var errorDescription: String? {
        switch self {
        case .signInRequired:
            L10n.signInPrompt
        case .unavailable:
            String(
                localized: "siri_shortcut_play_suggested_unavailable_error",
                defaultValue: "A suggested episode isn’t available right now.",
                table: "AppIntents"
            )
        case .playbackFailed:
            L10n.podcastDetailsPlaybackError
        }
    }
}

struct ResumePlaybackIntent: AudioPlaybackIntent {
    static var title = LocalizedStringResource(
        "siri_shortcut_resume_title",
        defaultValue: "Resume Current Episode",
        table: "Localizable"
    )
    static var description = IntentDescription(
        LocalizedStringResource(
            "siri_shortcut_resume_playback_description",
            defaultValue: "Resumes playback in Pocket Casts.",
            table: "AppIntents"
        )
    )
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }
    static var openAppWhenRun: Bool { false }

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background] }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await perform(using: SiriShortcutsManager.shared)
        return .result()
    }

    @MainActor
    func perform(using actionPerformer: any FixedSiriShortcutActionPerforming) async throws {
        switch await actionPerformer.perform(.resumePlayback) {
        case .success:
            return
        case .unavailable:
            throw ResumePlaybackIntentError.noEpisode
        case .playbackFailed:
            throw ResumePlaybackIntentError.playbackFailed
        }
    }
}

struct PausePlaybackIntent: AudioPlaybackIntent {
    static var title = LocalizedStringResource(
        "siri_shortcut_pause_title",
        defaultValue: "Pause Current Episode",
        table: "Localizable"
    )
    static var description = IntentDescription(
        LocalizedStringResource(
            "siri_shortcut_pause_playback_description",
            defaultValue: "Pauses playback in Pocket Casts.",
            table: "AppIntents"
        )
    )
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }
    static var openAppWhenRun: Bool { false }

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background] }

    @MainActor
    func perform() async throws -> some IntentResult {
        await perform(using: SiriShortcutsManager.shared)
        return .result()
    }

    @MainActor
    func perform(using actionPerformer: any FixedSiriShortcutActionPerforming) async {
        await actionPerformer.perform(.pausePlayback)
    }
}

struct PlayUpNextIntent: AudioPlaybackIntent {
    static var title = LocalizedStringResource(
        "siri_shortcut_play_up_next_intent_title",
        defaultValue: "Play Next Episode",
        table: "Localizable"
    )
    static var description = IntentDescription(
        LocalizedStringResource(
            "siri_shortcut_play_up_next_description",
            defaultValue: "Plays the first episode in the Pocket Casts Up Next queue.",
            table: "AppIntents"
        )
    )
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }
    static var openAppWhenRun: Bool { false }

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background] }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await perform(using: SiriShortcutsManager.shared)
        return .result()
    }

    @MainActor
    func perform(using actionPerformer: any FixedSiriShortcutActionPerforming) async throws {
        switch await actionPerformer.perform(.playUpNext) {
        case .success:
            return
        case .unavailable:
            throw PlayUpNextIntentError.noEpisode
        case .playbackFailed:
            throw PlayUpNextIntentError.playbackFailed
        }
    }
}

struct PlaySuggestedIntent: AudioPlaybackIntent {
    static var title = LocalizedStringResource(
        "siri_shortcut_play_suggested_intent_title",
        defaultValue: "Play a Suggested Episode",
        table: "Localizable"
    )
    static var description = IntentDescription(
        LocalizedStringResource(
            "siri_shortcut_play_suggested_description",
            defaultValue: "Plays a suggested episode in Pocket Casts.",
            table: "AppIntents"
        )
    )
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }
    static var openAppWhenRun: Bool { false }

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background] }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await perform(
            using: SiriShortcutsManager.shared,
            isUserLoggedIn: SyncManager.isUserLoggedIn()
        )
        return .result()
    }

    @MainActor
    func perform(using actionPerformer: any FixedSiriShortcutActionPerforming) async throws {
        try await perform(using: actionPerformer, isUserLoggedIn: true)
    }

    @MainActor
    func perform(
        using actionPerformer: any FixedSiriShortcutActionPerforming,
        isUserLoggedIn: Bool
    ) async throws {
        guard isUserLoggedIn else {
            throw PlaySuggestedIntentError.signInRequired
        }

        switch await actionPerformer.perform(.playSuggested) {
        case .success:
            return
        case .unavailable:
            throw PlaySuggestedIntentError.unavailable
        case .playbackFailed:
            throw PlaySuggestedIntentError.playbackFailed
        }
    }
}

struct ExtendSleepTimerIntent: AudioPlaybackIntent, CustomIntentMigratedAppIntent {
    static let intentClassName = "SJExtendSleepTimerIntent"

    static var title = LocalizedStringResource(
        "ny98Lo",
        defaultValue: "Extend Sleep Timer",
        table: "Intents"
    )
    static var description = IntentDescription(
        LocalizedStringResource(
            "siri_shortcut_extend_sleep_timer_description",
            defaultValue: "Extends the sleep timer by a chosen number of minutes.",
            table: "AppIntents"
        )
    )
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }
    static var openAppWhenRun: Bool { false }

    @Parameter(
        title: LocalizedStringResource(
            "siri_shortcut_extend_sleep_timer_minutes_title",
            defaultValue: "Minutes",
            table: "AppIntents"
        )
    )
    var minutes: Int?

    init() {
        minutes = 5
    }

    init(minutes: Int?) {
        self.minutes = minutes
    }

    static var parameterSummary: some ParameterSummary {
        Summary("siri_shortcut_extend_sleep_timer_parameter_summary", table: "AppIntents") {
            \.$minutes
        }
    }

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background] }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await perform(using: SiriShortcutsManager.shared)
        return .result()
    }

    @MainActor
    func perform(using actionPerformer: any FixedSiriShortcutActionPerforming) async throws {
        guard await actionPerformer.perform(.extendSleepTimer(minutes: try resolvedMinutes())) == .success else {
            throw ExtendSleepTimerIntentError.noActiveTimer
        }
    }

    private static let maxExtendableMinutes = Int(Constants.Limits.maxSleepTime) / 60

    private func resolvedMinutes() throws -> Int {
        guard let minutes else {
            return 5
        }

        guard (1...Self.maxExtendableMinutes).contains(minutes) else {
            throw ExtendSleepTimerIntentError.invalidMinutes
        }

        return minutes
    }
}
