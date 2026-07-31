import AppIntents

enum FixedSiriShortcutAction: Equatable {
    case extendSleepTimer(minutes: Int)
    case resumePlayback
    case pausePlayback
}

@MainActor
protocol FixedSiriShortcutActionPerforming {
    @discardableResult
    func perform(_ action: FixedSiriShortcutAction) -> Bool
}

extension SiriShortcutsManager: FixedSiriShortcutActionPerforming {
    @discardableResult
    func perform(_ action: FixedSiriShortcutAction) -> Bool {
        switch action {
        case let .extendSleepTimer(minutes):
            return extendSleepTimer(addTime: minutes)
        case .resumePlayback:
            return resumePlayback() == .success
        case .pausePlayback:
            return pausePlayback() == .success
        }
    }
}

enum ResumePlaybackIntentError: LocalizedError, Equatable {
    case noEpisode

    var errorDescription: String? {
        switch self {
        case .noEpisode:
            String(
                localized: "siri_shortcut_resume_playback_no_episode_error",
                defaultValue: "There’s no episode to resume.",
                table: "AppIntents"
            )
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
        try perform(using: SiriShortcutsManager.shared)
        return .result()
    }

    @MainActor
    func perform(using actionPerformer: any FixedSiriShortcutActionPerforming) throws {
        guard actionPerformer.perform(.resumePlayback) else {
            throw ResumePlaybackIntentError.noEpisode
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
        perform(using: SiriShortcutsManager.shared)
        return .result()
    }

    @MainActor
    func perform(using actionPerformer: any FixedSiriShortcutActionPerforming) {
        actionPerformer.perform(.pausePlayback)
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
            "EwNFJ5",
            defaultValue: "Extend Sleep Timer",
            table: "Intents"
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
        Summary("Extend Sleep Timer by \(\.$minutes) mins", table: "AppIntents")
    }

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background] }

    @MainActor
    func perform() async throws -> some IntentResult {
        perform(using: SiriShortcutsManager.shared)
        return .result()
    }

    @MainActor
    func perform(using actionPerformer: any FixedSiriShortcutActionPerforming) {
        actionPerformer.perform(.extendSleepTimer(minutes: resolvedMinutes))
    }

    private var resolvedMinutes: Int {
        guard let minutes, minutes > 0 else {
            return 5
        }

        return minutes
    }
}
