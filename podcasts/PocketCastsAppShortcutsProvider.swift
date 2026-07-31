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
    }
}
