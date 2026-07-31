import AppIntents

struct PocketCastsAppShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SetSleepTimerIntent(),
            phrases: [
                "\(.applicationName): Set sleep timer",
                "Start sleep timer in \(.applicationName)",
            ],
            shortTitle: LocalizedStringResource(
                "siri_shortcut_set_sleep_timer_title",
                defaultValue: "Set sleep timer",
                table: "AppIntents"
            ),
            systemImageName: "moon.zzz.fill"
        )
        AppShortcut(
            intent: ExtendSleepTimerIntent(),
            phrases: [
                "\(.applicationName): Extend Sleep Timer",
                "\(.applicationName): Extend sleep timer by 5 minutes",
            ],
            shortTitle: LocalizedStringResource(
                "ny98Lo",
                defaultValue: "Extend Sleep Timer",
                table: "Intents"
            ),
            systemImageName: "timer"
        )
        AppShortcut(
            intent: ResumePlaybackIntent(),
            phrases: [
                "\(.applicationName): Resume",
                "Continue playing in \(.applicationName)",
            ],
            shortTitle: LocalizedStringResource(
                "siri_shortcut_resume_title",
                defaultValue: "Resume Current Episode",
                table: "Localizable"
            ),
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: PausePlaybackIntent(),
            phrases: ["\(.applicationName): Pause"],
            shortTitle: LocalizedStringResource(
                "siri_shortcut_pause_title",
                defaultValue: "Pause Current Episode",
                table: "Localizable"
            ),
            systemImageName: "pause.fill"
        )
        AppShortcut(
            intent: PlayUpNextIntent(),
            phrases: [
                "\(.applicationName): Up Next",
                "Play the next episode in \(.applicationName)",
            ],
            shortTitle: LocalizedStringResource(
                "siri_shortcut_play_up_next_intent_title",
                defaultValue: "Play Next Episode",
                table: "Localizable"
            ),
            systemImageName: "text.line.first.and.arrowtriangle.forward"
        )
        AppShortcut(
            intent: PlaySuggestedIntent(),
            phrases: [
                "Play Suggested in \(.applicationName)",
                "\(.applicationName): Play a suggested episode",
            ],
            shortTitle: LocalizedStringResource(
                "siri_shortcut_play_suggested_intent_title",
                defaultValue: "Play a Suggested Episode",
                table: "Localizable"
            ),
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: NextChapterIntent(),
            phrases: ["\(.applicationName): Next chapter"],
            shortTitle: LocalizedStringResource(
                "siri_shortcut_next_chapter",
                defaultValue: "Next chapter",
                table: "Localizable"
            ),
            systemImageName: "forward.end.fill"
        )
    }
}
