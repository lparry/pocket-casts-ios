import PocketCastsUtils
// Placeholder so that PlayEpisodeIntent can compile in widget extension, but never actually executes
// because it is a subclass of AudioPlaybackIntent which only runs in the app.
extension PlayEpisodeIntent {
    func intentPlayback(_ episodeUuid: String) async -> Bool {
        FileLog.shared.addMessage("PlayEpisodeIntent error: In Widget intent extension \(episodeUuid)")
        return false
    }
}
