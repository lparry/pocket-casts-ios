import AppIntents
import WidgetKit
import PocketCastsUtils

enum PlayEpisodeIntentError: LocalizedError, Equatable {
    case playbackFailed

    var errorDescription: String? {
        L10n.podcastDetailsPlaybackError
    }
}

struct PlayEpisodeIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play episode"
    static var isDiscoverable = false // for now only to be used in the Now Playing widget

    @Parameter(title: "EpisodeUUID")
    var episodeUuid: String

    init(episodeUuid: String) {
        self.episodeUuid = episodeUuid
    }

    init() {}

    static var openAppWhenRun: Bool { return false }

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { return [.background] }

    @MainActor
    func perform() async throws -> some IntentResult {
        FileLog.shared.addMessage("PlayEpisodeIntent perform called for episode \(episodeUuid)")
        try await perform(using: intentPlayback)

        return .result()
    }

    @MainActor
    func perform(using playback: (String) async -> Bool) async throws {
        guard await playback(episodeUuid) else {
            throw PlayEpisodeIntentError.playbackFailed
        }
    }
}
