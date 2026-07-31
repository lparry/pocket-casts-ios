import AppIntents

enum FixedSiriShortcutAction: Equatable {
    case extendSleepTimer(minutes: Int)
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
        }
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
        guard await actionPerformer.perform(.extendSleepTimer(minutes: try resolvedMinutes())) else {
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
