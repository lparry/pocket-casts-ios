import AppIntents

enum FixedSiriShortcutAction: Equatable {
    case extendSleepTimer(minutes: Int)
}

@MainActor
protocol FixedSiriShortcutActionPerforming {
    func perform(_ action: FixedSiriShortcutAction)
}

extension SiriShortcutsManager: FixedSiriShortcutActionPerforming {
    func perform(_ action: FixedSiriShortcutAction) {
        switch action {
        case let .extendSleepTimer(minutes):
            _ = extendSleepTimer(addTime: minutes)
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
