import XCTest
@testable import podcasts
@testable import PocketCastsDataModel
@testable import PocketCastsUtils

final class PlaybackQueueTests: XCTestCase {

    let featureFlagMock = FeatureFlagMock()

    func testOverrideAllEpisodesWith_shouldNotIncludeStaleEpisodesInReplace() {
        FeatureFlagMock().set(.replaceSpecificEpisode, value: true)

        let playbackQueue = PlaybackQueue()
        let mockDataManager = MockDataManager()
        DataManager.sharedManager = mockDataManager

        let staleEpisode = PlaylistEpisode()
        staleEpisode.episodeUuid = "stale-uuid"
        staleEpisode.title = "Stale Episode"
        mockDataManager.upNextEpisodes = [staleEpisode]
        mockDataManager.delayCacheClearUntilManuallyCalled()

        let newEpisode = UserEpisode()
        newEpisode.uuid = "current-uuid"
        newEpisode.title = "Current Episode"

        playbackQueue.overrideAllEpisodesWith(episode: newEpisode)

        // Simulate delayed clearing of the cache
        mockDataManager.manuallyClearCache()

        // The replacement list should only contain the current episode (added later), not the stale one
        XCTAssertFalse(mockDataManager.savedReplaceEpisodes.contains("stale-uuid"),
                       "Should not include stale episode UUID in replacement list")
    }

    func testReorderUpNextPersistsNewOrderAndKeepsMissingEntriesAtBottom() {
        let playbackQueue = PlaybackQueue()
        let mockDataManager = MockDataManager()
        DataManager.sharedManager = mockDataManager

        // Position 0 is the now playing episode, which stays pinned and isn't reordered.
        mockDataManager.upNextEpisodes = [
            playlistEpisode(uuid: "now-playing", position: 0),
            playlistEpisode(uuid: "a", position: 1),
            playlistEpisode(uuid: "b", position: 2),
            playlistEpisode(uuid: "missing", position: 3) // no matching episode in sortedEpisodes
        ]

        // Desired new order for the known episodes.
        playbackQueue.reorderUpNext(sortedEpisodes: [episode("b"), episode("a")])

        let savedUuids = mockDataManager.savedPlaylistEpisodes.map { $0.episodeUuid }
        let savedPositions = mockDataManager.savedPlaylistEpisodes.map { $0.episodePosition }

        // The known episodes follow the sorted order, the missing entry sinks to the bottom...
        XCTAssertEqual(savedUuids, ["b", "a", "missing"])
        // ...and positions start at 1 since position 0 is reserved for the now playing episode.
        XCTAssertEqual(savedPositions, [1, 2, 3])
    }

    func testReorderUpNextDoesNothingWithFewerThanTwoSortedEpisodes() {
        let playbackQueue = PlaybackQueue()
        let mockDataManager = MockDataManager()
        DataManager.sharedManager = mockDataManager

        mockDataManager.upNextEpisodes = [
            playlistEpisode(uuid: "now-playing", position: 0),
            playlistEpisode(uuid: "a", position: 1)
        ]

        playbackQueue.reorderUpNext(sortedEpisodes: [episode("a")])

        XCTAssertTrue(mockDataManager.savedPlaylistEpisodes.isEmpty, "Reordering one episode should be a no-op")
    }

    func testAutoDownloadEntireQueueReturnsEveryEpisodeInOrder() {
        let queue = [
            playlistEpisode(uuid: "now-playing", position: 0),
            playlistEpisode(uuid: "a", position: 1),
            playlistEpisode(uuid: "b", position: 2)
        ]

        let result = PlaybackQueue.episodeUUIDsToAutoDownload(from: queue, limit: .entireQueue)

        XCTAssertEqual(result, ["now-playing", "a", "b"])
    }

    func testAutoDownloadLimitIncludesNowPlayingAndUsesQueuePositions() {
        let queue = (0 ..< 12).map {
            playlistEpisode(uuid: "episode-\($0)", position: Int32($0))
        }

        let result = PlaybackQueue.episodeUUIDsToAutoDownload(from: queue, limit: .ten)

        XCTAssertEqual(result, (0 ..< 10).map { "episode-\($0)" })
    }

    func testAutoDownloadLimitDoesNotBackfillPastUnresolvedQueueEntries() {
        let queue = (0 ..< 12).map {
            playlistEpisode(uuid: $0 == 4 ? "unresolved" : "episode-\($0)", position: Int32($0))
        }

        let result = PlaybackQueue.episodeUUIDsToAutoDownload(from: queue, limit: .ten)

        XCTAssertEqual(result.count, 10)
        XCTAssertTrue(result.contains("unresolved"))
        XCTAssertFalse(result.contains("episode-10"))
    }

    func testRetentionLimitOffloadsFurthestAutoDownloadsOutsideProtectedWindow() {
        let episodes = (0 ..< 15).map {
            downloadedEpisode("episode-\($0)")
        }
        let protectedUUIDs = Set((0 ..< 10).map { "episode-\($0)" })

        let result = PlaybackQueue.episodeUUIDsToOffload(
            from: episodes,
            protectedUUIDs: protectedUUIDs,
            currentEpisodeUUID: "episode-0",
            retentionLimit: .ten
        )

        XCTAssertEqual(result, ["episode-14", "episode-13", "episode-12", "episode-11", "episode-10"])
    }

    func testRetentionLimitDoesNotCountManualDownloads() {
        let autoDownloaded = (0 ..< 5).map {
            downloadedEpisode("auto-\($0)")
        }
        let manuallyDownloaded = (0 ..< 5).map {
            downloadedEpisode("manual-\($0)", autoDownloaded: false)
        }

        let result = PlaybackQueue.episodeUUIDsToOffload(
            from: autoDownloaded + manuallyDownloaded,
            protectedUUIDs: [],
            currentEpisodeUUID: nil,
            retentionLimit: .five
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testRetentionLimitPreservesStarredEpisodes() {
        let episodes = (0 ..< 12).map {
            downloadedEpisode("episode-\($0)", keepEpisode: $0 == 11)
        }
        let protectedUUIDs = Set((0 ..< 10).map { "episode-\($0)" })

        let result = PlaybackQueue.episodeUUIDsToOffload(
            from: episodes,
            protectedUUIDs: protectedUUIDs,
            currentEpisodeUUID: "episode-0",
            retentionLimit: .ten
        )

        XCTAssertEqual(result, ["episode-10"])
    }

    func testRetentionLimitDoesNotOffloadWhenThereIsNoLimit() {
        let episodes = (0 ..< 12).map {
            downloadedEpisode("episode-\($0)")
        }

        let result = PlaybackQueue.episodeUUIDsToOffload(
            from: episodes,
            protectedUUIDs: [],
            currentEpisodeUUID: nil,
            retentionLimit: .entireQueue
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testRetentionLimitSelectsActiveAutomaticDownloadsForRemoval() {
        let protectedEpisodes = (0 ..< 5).map {
            downloadedEpisode("episode-\($0)")
        }
        let queuedEpisode = autoDownloadEpisode("queued", status: .queued)
        let downloadingEpisode = autoDownloadEpisode("downloading", status: .downloading)
        let waitingEpisode = autoDownloadEpisode("waiting", status: .waitingForWifi)
        let manualDownload = autoDownloadEpisode("manual", status: .downloading, autoDownloaded: false)

        let result = PlaybackQueue.episodeUUIDsToOffload(
            from: protectedEpisodes + [queuedEpisode, downloadingEpisode, waitingEpisode, manualDownload],
            protectedUUIDs: Set(protectedEpisodes.map(\.uuid)),
            currentEpisodeUUID: "episode-0",
            retentionLimit: .five
        )

        XCTAssertEqual(result, ["waiting", "downloading", "queued"])
    }

    func testRetentionLimitCountsCompletedStreamingBuffers() {
        let protectedEpisodes = (0 ..< 5).map {
            downloadedEpisode("episode-\($0)")
        }
        let streamingBuffer = autoDownloadEpisode(
            "streaming-buffer",
            status: .downloadedForStreaming,
            autoDownloadStatus: .playerDownloadedForStreaming
        )

        let result = PlaybackQueue.episodeUUIDsToOffload(
            from: protectedEpisodes + [streamingBuffer],
            protectedUUIDs: Set(protectedEpisodes.map(\.uuid)),
            currentEpisodeUUID: "episode-0",
            retentionLimit: .five
        )

        XCTAssertEqual(result, ["streaming-buffer"])
    }

    func testRetentionLimitCountsStreamingBuffersPromotedToDownloads() {
        let protectedEpisodes = (0 ..< 5).map {
            downloadedEpisode("episode-\($0)")
        }
        let promotedStreamingBuffer = autoDownloadEpisode(
            "promoted-streaming-buffer",
            status: .downloaded,
            autoDownloadStatus: .playerDownloadedForStreaming
        )

        let result = PlaybackQueue.episodeUUIDsToOffload(
            from: protectedEpisodes + [promotedStreamingBuffer],
            protectedUUIDs: Set(protectedEpisodes.map(\.uuid)),
            currentEpisodeUUID: "episode-0",
            retentionLimit: .five
        )

        XCTAssertEqual(result, ["promoted-streaming-buffer"])
    }

    private func playlistEpisode(uuid: String, position: Int32) -> PlaylistEpisode {
        let playlistEpisode = PlaylistEpisode()
        playlistEpisode.episodeUuid = uuid
        playlistEpisode.episodePosition = position
        return playlistEpisode
    }

    private func episode(_ uuid: String) -> Episode {
        let episode = Episode()
        episode.uuid = uuid
        return episode
    }

    private func downloadedEpisode(_ uuid: String, autoDownloaded: Bool = true, keepEpisode: Bool = false) -> Episode {
        let episode = autoDownloadEpisode(
            uuid,
            status: .downloaded,
            autoDownloadStatus: autoDownloaded ? .autoDownloaded : .notSpecified
        )
        episode.keepEpisode = keepEpisode
        return episode
    }

    private func autoDownloadEpisode(_ uuid: String, status: DownloadStatus, autoDownloaded: Bool = true) -> Episode {
        autoDownloadEpisode(
            uuid,
            status: status,
            autoDownloadStatus: autoDownloaded ? .autoDownloaded : .notSpecified
        )
    }

    private func autoDownloadEpisode(_ uuid: String, status: DownloadStatus, autoDownloadStatus: AutoDownloadStatus) -> Episode {
        let episode = episode(uuid)
        episode.episodeStatus = status.rawValue
        episode.autoDownloadStatus = autoDownloadStatus.rawValue
        return episode
    }

    func testRecentUserInteractionReturnsFalseWhenNoPreviousInteraction() {
        let playbackQueue = PlaybackQueue()

        XCTAssertFalse(playbackQueue.recentUserInteraction(now: Date(timeIntervalSince1970: 15)))
    }

    func testRecentUserInteractionReturnsTrueWithinGracePeriod() {
        let playbackQueue = PlaybackQueue()
        let interactionTime = Date(timeIntervalSince1970: 1_000)
        playbackQueue.recordUpNextUserInteraction(at: interactionTime)

        XCTAssertTrue(playbackQueue.recentUserInteraction(now: interactionTime.addingTimeInterval(3)))
    }

    func testRecentUserInteractionReturnsFalseAtGracePeriodBoundary() {
        let playbackQueue = PlaybackQueue()
        let interactionTime = Date(timeIntervalSince1970: 1_000)
        playbackQueue.recordUpNextUserInteraction(at: interactionTime)

        XCTAssertFalse(playbackQueue.recentUserInteraction(now: interactionTime.addingTimeInterval(10)))
    }

    func testRecentUserInteractionReturnsFalseOutsideGracePeriod() {
        let playbackQueue = PlaybackQueue()
        let interactionTime = Date(timeIntervalSince1970: 1_000)
        playbackQueue.recordUpNextUserInteraction(at: interactionTime)

        XCTAssertFalse(playbackQueue.recentUserInteraction(now: interactionTime.addingTimeInterval(11)))
    }

    override func tearDown() {
        featureFlagMock.reset()
    }
}

fileprivate class MockDataManager: DataManager {
    var savedReplaceEpisodes: [String] = []
    var savedPlaylistEpisodes: [PlaylistEpisode] = []
    var upNextEpisodes: [PlaylistEpisode] = []
    var deleteCalled = false
    var cacheManuallyDelayed = false

    override func allUpNextPlaylistEpisodes() -> [PlaylistEpisode] {
        return upNextEpisodes
    }

    override func save(playlistEpisodes: [PlaylistEpisode]) {
        savedPlaylistEpisodes = playlistEpisodes
    }

    override func deleteAllUpNextEpisodes() {
        deleteCalled = true
        if !cacheManuallyDelayed {
            upNextEpisodes.removeAll()
        }
    }

    override func saveReplace(episodeList: [String]) {
        savedReplaceEpisodes = episodeList
    }

    // Allows simulating delay in cache clearing
    func delayCacheClearUntilManuallyCalled() {
        cacheManuallyDelayed = true
    }

    func manuallyClearCache() {
        upNextEpisodes.removeAll()
    }
}
