import XCTest
import PocketCastsDataModel
@testable import PocketCastsUtils
@testable import podcasts

final class SleepTimerPlaybackTests: DBTestCase {
    private let preferences = SleepTimerManager.Preferences()
    private let flags = FeatureFlagMock()
    private var savedDefaults: [String: Any] = [:]
    private var audioFiles: [URL] = []
    private let defaultsKeys = [
        Constants.UserDefaults.automaticSleepTimerMode,
        Constants.UserDefaults.sleepTimerTimeWindow,
        Constants.UserDefaults.sleepTimerSetting,
        Constants.UserDefaults.sleepTimerFinishedDate,
        Constants.UserDefaults.sleepTimerFinishedEpisodeUuid,
        Constants.UserDefaults.autoplay
    ]

    override func setUp() async throws {
        try await super.setUp()
        try await MainActor.run {
            for key in defaultsKeys {
                savedDefaults[key] = UserDefaults.standard.object(forKey: key)
                UserDefaults.standard.removeObject(forKey: key)
            }
            Settings.autoplay = false
            flags.set(.doNotSwitchToDownloadedFile, value: false)
            flags.set(.sleepTimerLiveActivity, value: false)
            let components = Calendar.current.dateComponents([.hour, .minute], from: .now)
            let minute = components.hour! * 60 + components.minute!
            preferences.mode = .timeWindow
            preferences.timeWindow = .init(startMinute: minute, endMinute: (minute + 60) % 1440)
            PlaybackManager.shared.endPlayback()
            PlaybackManager.shared.queue.clearUpNextList()
            try prepareAudio(for: episode)
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            PlaybackManager.shared.endPlayback()
            PlaybackManager.shared.queue.clearUpNextList()
            for key in defaultsKeys {
                UserDefaults.standard.set(savedDefaults[key], forKey: key)
            }
            flags.reset()
        }
        for url in audioFiles { try? FileManager.default.removeItem(at: url) }
        try await super.tearDown()
    }

    @MainActor
    func testResumingExpiredEpisodeTimerKeepsFinishedEpisodeThenArmsNextEpisode() async throws {
        let playback = PlaybackManager.shared
        playback.load(episode: episode, autoPlay: false, overrideUpNext: true)
        let next = Episode()
        next.uuid = UUID().uuidString
        next.podcastUuid = podcast.uuid
        next.podcast_id = podcast.id
        try prepareAudio(for: next)
        playback.queue.add(episode: next, fireNotification: false, partOfBulkAdd: false, toTop: false)
        playback.setSleepTimerEpisodeCount(1)

        // Deliver the same completion callback as the audio player at the timer's final episode.
        playback.playerDidFinishPlayingEpisode()
        XCTAssertEqual(playback.currentEpisode?.uuid, episode.uuid)
        XCTAssertFalse(playback.sleepTimerActive())

        await startPlayback { playback.play() }
        XCTAssertEqual(playback.currentEpisode?.uuid, episode.uuid)
        XCTAssertFalse(playback.sleepTimerActive())

        // The resumed episode can now finish normally and advance without consuming the new timer.
        await startPlayback { playback.playerDidFinishPlayingEpisode() }
        XCTAssertEqual(playback.currentEpisode?.uuid, next.uuid)
        XCTAssertEqual(playback.numberOfEpisodesToSleepAfter, 1)
    }

    @MainActor
    func testRewindingStoppedEpisodeRearmsTimerOnResume() async {
        let playback = PlaybackManager.shared
        playback.load(episode: episode, autoPlay: false, overrideUpNext: true)
        playback.setSleepTimerEpisodeCount(1)
        playback.playerDidFinishPlayingEpisode()
        XCTAssertEqual(preferences.finishedEpisodeUuid, episode.uuid)

        playback.seekTo(time: 0)
        await startPlayback { playback.play() }
        XCTAssertEqual(playback.currentEpisode?.uuid, episode.uuid)
        XCTAssertEqual(playback.numberOfEpisodesToSleepAfter, 1)
    }

    @MainActor
    func testDownloadReloadPreservesCancellationUntilDeliberatePlay() async {
        let playback = PlaybackManager.shared
        preferences.lastSetting = .init(duration: 1800, sleepOnEpisodeEnd: nil)
        await startPlayback { playback.load(episode: episode, autoPlay: true, overrideUpNext: true) }
        XCTAssertTrue(playback.sleepTimerActive())
        playback.cancelSleepTimer(userInitiated: true)

        await startPlayback {
            NotificationCenter.default.post(name: Constants.Notifications.episodeDownloaded, object: episode.uuid)
        }
        XCTAssertFalse(playback.sleepTimerActive())

        playback.pause()
        await startPlayback { playback.play() }
        XCTAssertTrue(playback.sleepTimerActive())
    }

    @MainActor
    private func startPlayback(_ action: () -> Void) async {
        let started = expectation(description: "Playback started")
        let observer = NotificationCenter.default.addObserver(forName: Constants.Notifications.playbackStarted, object: nil, queue: .main) { _ in
            started.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        action()
        await fulfillment(of: [started], timeout: 10)
    }

    @MainActor
    private func prepareAudio(for episode: Episode) throws {
        episode.title = "Sleep timer test"
        episode.fileType = "audio/mp4"
        episode.downloadUrl = "https://example.invalid/\(episode.uuid).m4a"
        episode.episodeStatus = DownloadStatus.downloaded.rawValue
        episode.duration = 13.140862
        episode.playingStatus = PlayingStatus.inProgress.rawValue
        episode.playedUpTo = 1
        dataManager.save(episode: episode)
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "no-metadata", withExtension: "m4a"))
        let destination = URL(fileURLWithPath: DownloadManager.shared.path(for: episode))
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: destination)
        audioFiles.append(destination)
    }
}
