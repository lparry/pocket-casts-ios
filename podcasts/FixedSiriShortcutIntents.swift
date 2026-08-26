import AppIntents

enum FixedSiriShortcutAction: Equatable {
    case extendSleepTimer(minutes: Int)
    case resumePlayback
    case pausePlayback
    case playUpNext
    case playSuggested
    case nextChapter
    case previousChapter
    case markAsPlayed
}

@MainActor
protocol FixedSiriShortcutActionPerforming {
    @discardableResult
    func perform(_ action: FixedSiriShortcutAction) async -> Bool
}

extension SiriShortcutsManager: FixedSiriShortcutActionPerforming {
    @discardableResult
    func perform(_ action: FixedSiriShortcutAction) async -> Bool {
        switch action {
        case let .extendSleepTimer(minutes):
            return extendSleepTimer(addTime: minutes)
        case .resumePlayback:
            return resumePlayback() == .success
        case .pausePlayback:
            return pausePlayback() == .success
        case .playUpNext:
            return playUpNext() == .success
        case .playSuggested:
            return await playSuggestedAsync() == .success
        case .nextChapter:
            return skipToNextChapter() == .success
        case .previousChapter:
            return skipToPreviousChapter() == .success
        case .markAsPlayed:
            return markAsPlayed() == .success
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

enum PlayUpNextIntentError: LocalizedError, Equatable {
    case noEpisode

    var errorDescription: String? {
        switch self {
        case .noEpisode:
            String(
                localized: "siri_shortcut_play_up_next_no_episode_error",
                defaultValue: "There’s no next episode in Up Next.",
                table: "AppIntents"
            )
        }
    }
}

enum PlaySuggestedIntentError: LocalizedError, Equatable {
    case unavailable

    var errorDescription: String? {
        switch self {
        case .unavailable:
            String(
                localized: "siri_shortcut_play_suggested_unavailable_error",
                defaultValue: "A suggested episode isn’t available right now.",
                table: "AppIntents"
            )
        }
    }
}

enum MarkAsPlayedIntentError: LocalizedError, Equatable {
    case noEpisode

    var errorDescription: String? {
        switch self {
        case .noEpisode:
            String(
                localized: "siri_shortcut_mark_as_played_no_episode_error",
                defaultValue: "There’s no current episode to mark as played.",
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
        try await perform(using: SiriShortcutsManager.shared)
        return .result()
    }

    @MainActor
    func perform(using actionPerformer: any FixedSiriShortcutActionPerforming) async throws {
        guard await actionPerformer.perform(.resumePlayback) else {
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
        "siri_shortcut_play_up_next_title",
        defaultValue: "Playing next episode",
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
        guard await actionPerformer.perform(.playUpNext) else {
            throw PlayUpNextIntentError.noEpisode
        }
    }
}

struct PlaySuggestedIntent: AudioPlaybackIntent {
    static var title = LocalizedStringResource(
        "siri_shortcut_play_suggested_podcast_title",
        defaultValue: "Playing a suggested episode",
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
        try await perform(using: SiriShortcutsManager.shared)
        return .result()
    }

    @MainActor
    func perform(using actionPerformer: any FixedSiriShortcutActionPerforming) async throws {
        guard await actionPerformer.perform(.playSuggested) else {
            throw PlaySuggestedIntentError.unavailable
        }
    }
}

struct NextChapterIntent: AudioPlaybackIntent {
    static var title = LocalizedStringResource(
        "siri_shortcut_next_chapter",
        defaultValue: "Next chapter",
        table: "Localizable"
    )
    static var description = IntentDescription(
        LocalizedStringResource(
            "siri_shortcut_next_chapter_description",
            defaultValue: "Skips to the next chapter in Pocket Casts.",
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
        await actionPerformer.perform(.nextChapter)
    }
}

struct PreviousChapterIntent: AudioPlaybackIntent {
    static var title = LocalizedStringResource(
        "siri_shortcut_previous_chapter",
        defaultValue: "Previous chapter",
        table: "Localizable"
    )
    static var description = IntentDescription(
        LocalizedStringResource(
            "siri_shortcut_previous_chapter_description",
            defaultValue: "Skips to the previous chapter in Pocket Casts.",
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
        await actionPerformer.perform(.previousChapter)
    }
}

struct MarkAsPlayedIntent: AudioPlaybackIntent {
    static var title = LocalizedStringResource(
        "siri_shortcut_mark_as_played_title",
        defaultValue: "Mark Current Episode as Played",
        table: "Localizable"
    )
    static var description = IntentDescription(
        LocalizedStringResource(
            "siri_shortcut_mark_as_played_description",
            defaultValue: "Marks the current Pocket Casts episode as played.",
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
        guard await actionPerformer.perform(.markAsPlayed) else {
            throw MarkAsPlayedIntentError.noEpisode
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
        await perform(using: SiriShortcutsManager.shared)
        return .result()
    }

    @MainActor
    func perform(using actionPerformer: any FixedSiriShortcutActionPerforming) async {
        await actionPerformer.perform(.extendSleepTimer(minutes: resolvedMinutes))
    }

    private var resolvedMinutes: Int {
        guard let minutes, minutes > 0 else {
            return 5
        }

        return minutes
    }
}
