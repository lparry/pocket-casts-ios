import AVFoundation
import BackgroundTasks
import Combine
import Foundation
import os
import PocketCastsDataModel
import PocketCastsUtils
import UIKit

/// Finds the ads in downloaded episodes and tells playback which ones to skip.
///
/// Every downloaded episode is scanned once for each file it's downloaded as: when a download
/// finishes, and as a backfill whenever the app launches or comes to the foreground. A background
/// processing task carries on with the queue while the device is charging. The local file is
/// transcribed on device and the timestamped transcript goes to an `AdClassifier`: OpenRouter, with
/// the listener's own key, falling back to Apple's on-device model only if OpenRouter's answer can't be used.
/// When OpenRouter can't be reached the scan fails and is tried again later. Nothing is scanned without a key. The resulting spans are in the timeline of that download, so they're only used
/// while it's still the file on disk.
///
/// Processing runs on the main actor, but playback reads spans from the progress tick, so that state is behind a lock.
final class AdSkippingManager: ObservableObject, @unchecked Sendable {
    static let shared = AdSkippingManager()

    static let backgroundTaskIdentifier = "au.com.shiftyjelly.podcasts.AdSkipping"

    enum Status: Equatable {
        case queued
        /// `progress` runs from 0 to 1, once the first part of the transcript is in
        case transcribing(progress: Double?, timeLeft: TimeInterval?)
        case classifying
        case finished(adCount: Int, classifier: String)
        case failed(String)
    }

    /// The status of each episode queued since launch
    @MainActor
    @Published private(set) var statuses: [String: Status] = [:]

    /// Bumped whenever a stored analysis changes, so the settings screen can reload
    @MainActor
    @Published private(set) var analysesVersion = 0

    let store: AdSpanStore
    private let transcriptStore: TranscriptStore
    private let failureStore: AdScanFailureStore

    private let transcriberProvider: () -> EpisodeTranscriber?
    private let classifiersProvider: (_ openRouterApiKey: String?, _ openRouterModel: String) -> [AdClassifier]
    private let dataManager: DataManager

    @MainActor
    private var pending: [String] = []
    @MainActor
    private var processingUuid: String?
    @MainActor
    private var processingTask: Task<Void, Never>?
    /// Keeps a scan going for a while after the app is backgrounded
    @MainActor
    private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
    /// Episodes that failed for a reason that may clear up, like no network, so they're tried again on the next foreground
    @MainActor
    private var retryableFailures: Set<String> = []
    @MainActor
    private var idleContinuations: [CheckedContinuation<Void, Never>] = []
    /// Set when a background task runs out of time, so nothing new starts until the app is next active
    @MainActor
    private var isPaused = false

    private struct PlaybackState {
        /// Spans the listener chose to hear with Undo, keyed by episode, so they aren't skipped again this session
        var restoredSpans: [String: Set<AdSpan>] = [:]

        /// Whether each episode's stored analysis was made from the file that's on disk now
        var analysisMatchesFile: [String: Bool] = [:]

        /// The kinds of ad the listener wants skipped
        var skippedKinds: Set<AdSpan.Kind> = AdSkippingManager.loadSkippedKinds()

        /// Podcasts the listener knows are ad free, so they're never scanned or skipped
        var unscannedPodcasts: Set<String> = Set(UserDefaults.standard.stringArray(forKey: AdSkippingManager.unscannedPodcastsDefaultsKey) ?? [])
    }

    private let playbackState = OSAllocatedUnfairLock(initialState: PlaybackState())

    init(store: AdSpanStore = AdSpanStore(),
         transcriptStore: TranscriptStore = TranscriptStore(),
         failureStore: AdScanFailureStore = AdScanFailureStore(),
         dataManager: DataManager = .shared,
         transcriberProvider: (() -> EpisodeTranscriber?)? = nil,
         classifiersProvider: ((_ openRouterApiKey: String?, _ openRouterModel: String) -> [AdClassifier])? = nil) {
        self.store = store
        self.transcriptStore = transcriptStore
        self.failureStore = failureStore
        self.dataManager = dataManager
        self.transcriberProvider = transcriberProvider ?? {
            if #available(iOS 26, *) {
                return SpeechAnalyzerTranscriber()
            }
            return nil
        }
        self.classifiersProvider = classifiersProvider ?? Self.defaultClassifiers
    }

    /// Call while the app is finishing launching, so the background task is registered in time
    @MainActor
    func setup() {
        NotificationCenter.default.addObserver(self, selector: #selector(episodeDownloaded(_:)), name: Constants.Notifications.episodeDownloaded, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(didBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)

        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.backgroundTaskIdentifier, using: .main) { [weak self] task in
            guard let self, let task = task as? BGProcessingTask else { return }
            MainActor.assumeIsolated {
                self.handleBackgroundTask(task)
            }
        }
    }

    // MARK: - OpenRouter

    private static let apiKeyKeychainKey = "AdSkippingOpenRouterApiKey"
    private static let modelDefaultsKey = "AdSkippingOpenRouterModel"

    @MainActor
    var openRouterApiKey: String? {
        get {
            (try? KeychainHelper.string(for: Self.apiKeyKeychainKey))?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmptyString
        }
        set {
            if let newValue = newValue?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmptyString {
                KeychainHelper.save(string: newValue, key: Self.apiKeyKeychainKey, accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
            } else {
                KeychainHelper.removeKey(Self.apiKeyKeychainKey)
            }
            objectWillChange.send()
            classifiersChanged()
        }
    }

    /// The OpenRouter model slug, like `anthropic/claude-sonnet-5.5`
    @MainActor
    var openRouterModel: String {
        get {
            UserDefaults.standard.string(forKey: Self.modelDefaultsKey)?.nilIfEmptyString ?? OpenRouterAdClassifier.defaultModel
        }
        set {
            let model = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard model != openRouterModel else { return }

            UserDefaults.standard.set(model.isEmpty ? nil : model, forKey: Self.modelDefaultsKey)
            objectWillChange.send()
            classifiersChanged()
        }
    }

    /// The classifiers to try, in order
    @MainActor
    var classifiers: [AdClassifier] {
        classifiersProvider(openRouterApiKey, openRouterModel)
    }

    /// OpenRouter finds the ads. The on-device model is too unreliable to use on its own, so it's only a backup for
    /// when OpenRouter's answer can't be used, and nothing is scanned without a key.
    private static func defaultClassifiers(openRouterApiKey: String?, openRouterModel: String) -> [AdClassifier] {
        guard let openRouterApiKey else { return [] }

        var classifiers: [AdClassifier] = [OpenRouterAdClassifier(apiKey: openRouterApiKey, model: openRouterModel)]
        if #available(iOS 26, *), FoundationModelsAdClassifier.isAvailable {
            classifiers.append(FoundationModelsAdClassifier())
        }
        return classifiers
    }

    /// Identifies a set of classifiers, so a failure is only remembered until the model or key changes
    static func classifiersKey(_ classifiers: [AdClassifier]) -> String {
        classifiers.map(\.identifier).joined(separator: ",")
    }

    /// Episodes that failed may work with different classifiers, so give them another go
    @MainActor
    private func classifiersChanged() {
        statuses = statuses.filter { _, status in
            if case .failed = status { return false }
            return true
        }
        retryableFailures.removeAll()
        scanMissing()
    }

    // MARK: - Kinds

    private static let skippedKindsDefaultsKey = "AdSkippingSkippedKinds"

    /// Every kind is skipped until the listener turns one off. Spans keep their kind, so changing this needs no rescan.
    var skippedKinds: Set<AdSpan.Kind> {
        playbackState.withLock { $0.skippedKinds }
    }

    @MainActor
    func setSkipping(_ kind: AdSpan.Kind, _ skip: Bool) {
        let kinds = playbackState.withLock { state in
            if skip {
                state.skippedKinds.insert(kind)
            } else {
                state.skippedKinds.remove(kind)
            }
            return state.skippedKinds
        }
        UserDefaults.standard.set(kinds.map(\.rawValue).sorted(), forKey: Self.skippedKindsDefaultsKey)
        objectWillChange.send()
    }

    private static func loadSkippedKinds() -> Set<AdSpan.Kind> {
        guard let rawValues = UserDefaults.standard.stringArray(forKey: skippedKindsDefaultsKey) else {
            return Set(AdSpan.Kind.allCases)
        }
        return Set(rawValues.compactMap(AdSpan.Kind.init(rawValue:)))
    }

    // MARK: - Podcasts

    private static let unscannedPodcastsDefaultsKey = "AdSkippingUnscannedPodcasts"

    func isScanning(podcastUuid: String) -> Bool {
        !playbackState.withLock { $0.unscannedPodcasts.contains(podcastUuid) }
    }

    /// Whether ads are found and skipped in this episode's podcast. Files the listener uploaded are always scanned.
    func isScanning(_ episode: BaseEpisode) -> Bool {
        guard let episode = episode as? Episode else { return true }
        return isScanning(podcastUuid: episode.podcastUuid)
    }

    @MainActor
    func setScanning(_ scan: Bool, podcastUuid: String) {
        let podcasts = playbackState.withLock { state in
            if scan {
                state.unscannedPodcasts.remove(podcastUuid)
            } else {
                state.unscannedPodcasts.insert(podcastUuid)
            }
            return state.unscannedPodcasts
        }
        UserDefaults.standard.set(podcasts.sorted(), forKey: Self.unscannedPodcastsDefaultsKey)
        objectWillChange.send()

        if scan {
            scanMissing()
        } else {
            let episodeUuids = Set(pending.filter { uuid in
                dataManager.findEpisode(uuid: uuid)?.podcastUuid == podcastUuid
            })
            pending.removeAll { episodeUuids.contains($0) }
            for uuid in episodeUuids {
                statuses[uuid] = nil
            }
        }
    }

    // MARK: - Playback

    /// Ads in the same break are joined into one skip when they're at most this far apart, so the jingles and pauses between them don't play
    static let breakGap: TimeInterval = 8

    /// What to skip at `time`, if it's in an ad
    func adSkip(in episode: BaseEpisode, at time: TimeInterval) -> AdSkip? {
        guard let (spans, kinds, restored) = skippableSpans(in: episode) else { return nil }
        return Self.adSkip(in: spans, at: time, skipping: kinds, restored: restored)
    }

    /// When the next ad starts, if it's after `time` and no more than `within` away
    func nextAdStart(in episode: BaseEpisode, after time: TimeInterval, within: TimeInterval) -> TimeInterval? {
        guard let (spans, kinds, restored) = skippableSpans(in: episode) else { return nil }
        return spans.first { $0.start > time && $0.start - time <= within && kinds.contains($0.kind) && !restored.contains($0) }?.start
    }

    private func skippableSpans(in episode: BaseEpisode) -> ([AdSpan], Set<AdSpan.Kind>, Set<AdSpan>)? {
        guard FeatureFlag.autoAdSkip.enabled, isScanning(episode), let analysis = currentAnalysis(for: episode), !analysis.isSuspect, !analysis.spans.isEmpty else {
            return nil
        }

        let (restored, skippedKinds) = playbackState.withLock { ($0.restoredSpans[episode.uuid] ?? [], $0.skippedKinds) }
        return (analysis.spans, skippedKinds, restored)
    }

    static func adSkip(in spans: [AdSpan], at time: TimeInterval, skipping kinds: Set<AdSpan.Kind>, restored: Set<AdSpan>) -> AdSkip? {
        let skippable = spans.filter { kinds.contains($0.kind) && !restored.contains($0) }.sorted { $0.start < $1.start }
        guard let index = skippable.firstIndex(where: { $0.contains(time) }) else { return nil }

        var joined = [skippable[index]]
        for span in skippable[(index + 1)...] {
            guard let last = joined.last, span.start - last.end <= breakGap else { break }
            joined.append(span)
        }

        let skip = AdSkip(spans: joined)
        // Don't bother skipping the last moment of an ad
        return skip.end - time > 1 ? skip : nil
    }

    /// Stops these ads being skipped again until the next launch
    func restore(_ spans: [AdSpan], in episodeUuid: String) {
        playbackState.withLock { $0.restoredSpans[episodeUuid, default: []].formUnion(spans) }
    }

    /// The stored analysis, if it was made from the download that's on disk now. Spans never line up with a stream.
    func currentAnalysis(for episode: BaseEpisode) -> EpisodeAdAnalysis? {
        guard let analysis = store.analysis(for: episode.uuid), episode.downloaded(pathFinder: DownloadManager.shared) else { return nil }

        if let matches = playbackState.withLock({ $0.analysisMatchesFile[episode.uuid] }) {
            return matches ? analysis : nil
        }

        let matches = analysis.audioFileSize == Self.fileSize(of: episode)
        playbackState.withLock { $0.analysisMatchesFile[episode.uuid] = matches }
        return matches ? analysis : nil
    }

    private func forgetFileMatch(for episodeUuid: String) {
        playbackState.withLock { $0.analysisMatchesFile[episodeUuid] = nil }
    }

    // MARK: - Queue

    @MainActor
    @objc private func episodeDownloaded(_ notification: Notification) {
        guard FeatureFlag.autoAdSkip.enabled, let uuid = notification.object as? String else { return }

        // A new download can have different ads inserted, so always start over
        forgetFileMatch(for: uuid)
        enqueue(uuid, force: true)
    }

    @MainActor
    @objc private func didBecomeActive() {
        isPaused = false
        scanMissing()
    }

    /// Queues an episode for scanning. Without `force`, episodes already scanned for the file on disk are skipped.
    @MainActor
    func enqueue(_ episodeUuid: String, force: Bool = false, first: Bool = false) {
        guard FeatureFlag.autoAdSkip.enabled, processingUuid != episodeUuid else { return }
        guard let episode = dataManager.findBaseEpisode(uuid: episodeUuid), isScanning(episode) else { return }
        guard force || (currentAnalysis(for: episode) == nil && !hasKnownFailure(episode, classifiers: Self.classifiersKey(classifiers))) else { return }

        pending.removeAll { $0 == episodeUuid }
        retryableFailures.remove(episodeUuid)
        if first {
            pending.insert(episodeUuid, at: 0)
        } else {
            pending.append(episodeUuid)
        }
        statuses[episodeUuid] = .queued
        processNextIfNeeded()
    }

    /// Queues every downloaded episode that hasn't been scanned for the file on disk, playing and Up Next first.
    ///
    /// A permanent failure isn't tried again, even after a relaunch, until the file or the classifiers change, so a transcript
    /// that can't be classified isn't sent and paid for over and over. `enqueue` with `force` still tries it on request.
    /// Failures that may clear up, like no network, are always retried.
    @MainActor
    func scanMissing() {
        guard FeatureFlag.autoAdSkip.enabled else { return }

        let downloaded = downloadedEpisodes()
        let downloadedUuids = Set(downloaded.map(\.uuid))
        transcriptStore.removeAll(except: downloadedUuids)
        store.removeAll(except: downloadedUuids)
        failureStore.removeAll(except: downloadedUuids)

        // Without a classifier every scan would fail, so wait for a key
        let classifiers = classifiers
        guard !classifiers.isEmpty else { return }

        let classifiersKey = Self.classifiersKey(classifiers)
        let episodes = downloaded.filter { isScanning($0) }
        let skipped = Set(episodes.filter { currentAnalysis(for: $0) != nil || hasKnownFailure($0, classifiers: classifiersKey) }.map(\.uuid))
        let upNext = PlaybackManager.shared.queue.allEpisodes(includeNowPlaying: true).map(\.uuid)
        let ordered = Self.scanOrder(downloaded: episodes.map(\.uuid), upNext: upNext)

        let toScan = ordered.filter { uuid in
            guard uuid != processingUuid, !skipped.contains(uuid) else { return false }
            if case .failed = statuses[uuid] {
                return retryableFailures.contains(uuid)
            }
            return true
        }
        guard !toScan.isEmpty else { return }

        pending = toScan + pending.filter { !toScan.contains($0) }
        for uuid in toScan {
            statuses[uuid] = .queued
        }
        processNextIfNeeded()
    }

    /// Up Next comes first, in its order, then everything else in the order given
    static func scanOrder(downloaded: [String], upNext: [String]) -> [String] {
        let downloadedSet = Set(downloaded)
        let first = upNext.filter { downloadedSet.contains($0) }
        let firstSet = Set(first)
        return first + downloaded.filter { !firstSet.contains($0) }
    }

    /// Every downloaded episode, most recently downloaded first
    @MainActor
    func downloadedEpisodes() -> [BaseEpisode] {
        dataManager.findDownloadedEpisodes().filter { $0.downloaded(pathFinder: DownloadManager.shared) }
    }

    /// Why this download couldn't be scanned, if it failed for good
    @MainActor
    func scanFailure(for episode: BaseEpisode) -> AdScanFailure? {
        guard let failure = failureStore.failure(for: episode.uuid), failure.audioFileSize == Self.fileSize(of: episode) else { return nil }
        return failure
    }

    // MARK: - Checking Ads

    /// The words spoken in each ad, read from the download's saved transcript, or nil if it wasn't kept
    @MainActor
    func adTranscripts(for episode: BaseEpisode, spans: [AdSpan]) async -> [AdSpan: AdTranscriptExcerpt]? {
        await Self.loadAdTranscripts(spans: spans, episodeUuid: episode.uuid, audioFileSize: Self.fileSize(of: episode), from: transcriptStore)
    }

    /// A long transcript takes a moment to read, so it's read off the main thread
    @concurrent
    private static func loadAdTranscripts(spans: [AdSpan], episodeUuid: String, audioFileSize: UInt64?, from transcriptStore: TranscriptStore) async -> [AdSpan: AdTranscriptExcerpt]? {
        guard let saved = transcriptStore.transcript(for: episodeUuid, audioFileSize: audioFileSize) else { return nil }
        return adTranscripts(of: spans, in: saved.segments)
    }

    /// The words whose middle falls within each ad, along with a few seconds either side so its edges can be checked
    static func adTranscripts(of spans: [AdSpan], in transcript: [TranscriptSegment], context: TimeInterval = 5) -> [AdSpan: AdTranscriptExcerpt] {
        // Lines without word timings count as one long word
        let words = transcript.flatMap { segment in
            segment.words.isEmpty ? [TimedWord(start: segment.start, end: segment.end, text: segment.text)] : segment.words
        }

        func text(from start: TimeInterval, to end: TimeInterval) -> String {
            words
                .filter { word in
                    let middle = (word.start + word.end) / 2
                    return middle >= start && middle < end
                }
                .map(\.text)
                .joined(separator: " ")
        }

        var excerpts: [AdSpan: AdTranscriptExcerpt] = [:]
        for span in spans {
            excerpts[span] = AdTranscriptExcerpt(before: text(from: span.start - context, to: span.start),
                                                 ad: text(from: span.start, to: span.end),
                                                 after: text(from: span.end, to: span.end + context))
        }
        return excerpts
    }

    /// Plays from just before an ad, and lets it play this session, so the listener can hear what was found
    @MainActor
    func play(_ span: AdSpan, in episode: BaseEpisode) {
        restore([span], in: episode.uuid)

        let time = max(0, span.start - 3)
        let playbackManager = PlaybackManager.shared
        if playbackManager.isCurrentEpisode(uuid: episode.uuid) {
            playbackManager.seekTo(time: time, startPlaybackAfterSeek: true)
            return
        }

        // Like playing a bookmark, start the episode where the player should pick it up
        dataManager.saveEpisode(playedUpTo: time, episode: episode, updateSyncFlag: false)
        dataManager.saveEpisode(playingStatus: .inProgress, episode: episode, updateSyncFlag: false)
        PlaybackActionHelper.play(episode: episode)
    }

    @MainActor
    private func hasKnownFailure(_ episode: BaseEpisode, classifiers: String) -> Bool {
        failureStore.failure(for: episode.uuid)?.matches(audioFileSize: Self.fileSize(of: episode), classifiers: classifiers) == true
    }

    @MainActor
    func removeAnalysis(for episodeUuid: String) {
        store.remove(episodeUuid)
        forgetFileMatch(for: episodeUuid)
        statuses[episodeUuid] = nil
        analysesVersion += 1
    }

    // MARK: - Processing

    @MainActor
    private func processNextIfNeeded() {
        guard processingUuid == nil, !isPaused else { return }

        guard !pending.isEmpty else {
            resumeIdleWaiters()
            return
        }

        let uuid = pending.removeFirst()
        processingUuid = uuid

        processingTask = Task {
            await process(uuid)
            processingUuid = nil
            processingTask = nil
            processNextIfNeeded()
        }
    }

    @MainActor
    private func process(_ uuid: String) async {
        beginBackgroundTask()
        defer {
            endBackgroundTask()
        }

        retryableFailures.remove(uuid)

        // Captured before the scan, so a failure is tied to the file and classifiers it happened with
        let classifiersKey = Self.classifiersKey(classifiers)
        let fileSize = dataManager.findBaseEpisode(uuid: uuid).flatMap { Self.fileSize(of: $0) }

        do {
            let (spans, classifier) = try await analyze(uuid)
            failureStore.remove(uuid)
            statuses[uuid] = .finished(adCount: spans.count, classifier: classifier)
            FileLog.shared.addMessage("AdSkipping: \(classifier) found \(spans.count) ads in \(uuid)")
        } catch where Task.isCancelled {
            // Interrupted, not failed, so pick it up again next time
            pending.insert(uuid, at: 0)
            statuses[uuid] = .queued
            FileLog.shared.addMessage("AdSkipping: interrupted while scanning \(uuid)")
        } catch {
            statuses[uuid] = .failed(error.localizedDescription)
            if AdSkippingError.isRetryable(error) {
                retryableFailures.insert(uuid)
            } else if AdSkippingError.isPermanent(error) {
                let failure = AdScanFailure(audioFileSize: fileSize, classifiers: classifiersKey, message: error.localizedDescription, failedAt: Date())
                try? failureStore.save(failure, for: uuid)
            }
            FileLog.shared.addMessage("AdSkipping: failed to scan \(uuid): \(error)")
        }
    }

    /// Transcribing a long episode takes a while, so ask for time to finish if the app is backgrounded.
    /// If that time runs out, the scan stops and is picked up again later, so iOS doesn't end the app.
    @MainActor
    private func beginBackgroundTask() {
        endBackgroundTask()
        backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "AdSkipping") { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }

                FileLog.shared.addMessage("AdSkipping: ran out of background time, pausing until the app is next active")
                self.isPaused = true
                self.processingTask?.cancel()
                self.scheduleBackgroundScanningIfNeeded()
                self.endBackgroundTask()
            }
        }
    }

    @MainActor
    private func endBackgroundTask() {
        guard backgroundTaskId != .invalid else { return }

        UIApplication.shared.endBackgroundTask(backgroundTaskId)
        backgroundTaskId = .invalid
    }

    @MainActor
    private func analyze(_ uuid: String) async throws -> (spans: [AdSpan], classifier: String) {
        guard let episode = dataManager.findBaseEpisode(uuid: uuid), episode.downloaded(pathFinder: DownloadManager.shared) else {
            throw AdSkippingError.notDownloaded
        }

        let classifiers = classifiers
        guard !classifiers.isEmpty else {
            throw AdSkippingError.noClassifier
        }

        let fileURL = URL(fileURLWithPath: episode.pathToDownloadedFile(pathFinder: DownloadManager.shared))
        let fileSize = Self.fileSize(of: episode)
        let clock = ContinuousClock()
        var timings = AdScanTimings()

        let transcript: [TranscriptSegment]
        if let saved = transcriptStore.transcript(for: uuid, audioFileSize: fileSize) {
            transcript = saved.segments
            timings.audioDuration = saved.audioDuration
        } else {
            guard let transcriber = transcriberProvider() else {
                throw AdSkippingError.transcriptionUnavailable
            }

            statuses[uuid] = .transcribing(progress: nil, timeLeft: nil)
            let audioDuration = Self.audioDuration(of: fileURL)
            let started = clock.now
            // Podcasts don't record their language, so assume they're in the listener's
            transcript = try await transcriber.transcribe(fileURL: fileURL, locale: Locale.current) { [weak self] progress in
                Task { @MainActor in
                    self?.transcriptionProgressed(uuid, progress: progress, since: started, clock: clock)
                }
            }
            try Task.checkCancellation()

            timings.audioDuration = audioDuration
            timings.transcription = (clock.now - started).seconds
            try? transcriptStore.save(transcript, for: uuid, audioFileSize: fileSize, audioDuration: audioDuration)
        }

        guard !transcript.isEmpty else {
            throw AdSkippingError.emptyTranscript
        }

        statuses[uuid] = .classifying
        let podcastTitle = (episode as? Episode)?.parentPodcast(dataManager: dataManager)?.title
        // The episode's duration isn't always known yet, but the transcript runs nearly to the end
        let duration = episode.duration > 0 ? episode.duration : transcript.last?.end ?? 0
        let context = AdClassificationContext(podcastTitle: podcastTitle, episodeTitle: episode.title, duration: duration)

        var started = clock.now
        let classification: (spans: [AdSpan], classifier: AdClassifier, isSuspect: Bool)
        do {
            classification = try await Self.classify(transcript, context: context, using: classifiers)
        } catch let error as AdSkippingError {
            throw error
        } catch where !Task.isCancelled && !AdSkippingError.isRetryable(error) {
            // Like an answer that doesn't decode, which will be the same next time
            throw AdSkippingError.classifierFailed(error.localizedDescription)
        }
        let (foundSpans, classifier, isSuspect) = classification
        try Task.checkCancellation()
        timings.firstPass = (clock.now - started).seconds

        // Pin each edge to the exact word, then widen it over any jingle or pause in the audio
        let words = transcript.flatMap(\.words)
        started = clock.now
        let refinedSpans = try await AdBoundaryRefiner(classifier: classifier).refine(foundSpans, words: words, context: context)
        try Task.checkCancellation()
        timings.edgePass = (clock.now - started).seconds

        started = clock.now
        let snappedSpans = await AudioBoundarySnapper.snap(refinedSpans, words: words, fileURL: fileURL)
        timings.audioSnapping = (clock.now - started).seconds
        let spans = classifier.cleanedUp(snappedSpans, duration: context.duration)

        FileLog.shared.addMessage("AdSkipping: timings for \(uuid): \(timings.logDescription)")

        let analysis = EpisodeAdAnalysis(version: EpisodeAdAnalysis.currentVersion,
                                         episodeUuid: uuid,
                                         analyzedAt: Date(),
                                         classifier: classifier.identifier,
                                         audioFileSize: fileSize,
                                         transcriptSegmentCount: transcript.count,
                                         spans: spans,
                                         isSuspect: isSuspect,
                                         timings: timings)
        try store.save(analysis)
        forgetFileMatch(for: uuid)
        analysesVersion += 1

        return (spans, classifier.identifier)
    }

    /// Uses the first classifier that gives an answer, moving on only when one's answer can't be used.
    ///
    /// An implausible answer is kept and marked suspect rather than handed to a less reliable backup. A classifier that can't be
    /// reached stops the scan, since the backup's answer would be kept for good when the first one would work again soon.
    static func classify(_ transcript: [TranscriptSegment], context: AdClassificationContext, using classifiers: [AdClassifier]) async throws -> (spans: [AdSpan], classifier: AdClassifier, isSuspect: Bool) {
        var lastError: Error = AdSkippingError.noClassifier
        for classifier in classifiers {
            do {
                let spans = try await classifier.adSpans(in: transcript, context: context)
                let isSuspect = EpisodeAdAnalysis.looksWrong(spans, duration: context.duration)
                if isSuspect {
                    FileLog.shared.addMessage("AdSkipping: \(classifier.identifier) found \(spans.count) ads, which looks wrong, so they won't be skipped")
                }
                return (spans, classifier, isSuspect)
            } catch {
                try Task.checkCancellation()
                if AdSkippingError.isRetryable(error) {
                    throw error
                }
                FileLog.shared.addMessage("AdSkipping: \(classifier.identifier) failed, trying the next classifier: \(error)")
                lastError = error
            }
        }

        throw lastError
    }

    @MainActor
    private func transcriptionProgressed(_ uuid: String, progress: Double, since started: ContinuousClock.Instant, clock: ContinuousClock) {
        // Updates can arrive after the transcript is done
        guard case .transcribing = statuses[uuid] else { return }

        let elapsed = (clock.now - started).seconds
        let timeLeft = progress > 0.02 ? elapsed * (1 - progress) / progress : nil
        statuses[uuid] = .transcribing(progress: progress, timeLeft: timeLeft)
    }

    private static func audioDuration(of fileURL: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: fileURL) else { return nil }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    private static func fileSize(of episode: BaseEpisode) -> UInt64? {
        let path = episode.pathToDownloadedFile(pathFinder: DownloadManager.shared)
        return (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value
    }

    // MARK: - Background Processing

    @MainActor
    @objc private func didEnterBackground() {
        scheduleBackgroundScanningIfNeeded()
    }

    @MainActor
    private func scheduleBackgroundScanningIfNeeded() {
        guard processingUuid != nil || !pending.isEmpty else { return }

        // Transcription is heavy, so only carry on in the background while charging
        let request = BGProcessingTaskRequest(identifier: Self.backgroundTaskIdentifier)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = false

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            FileLog.shared.addMessage("AdSkipping: couldn't schedule background scanning: \(error)")
        }
    }

    @MainActor
    private func handleBackgroundTask(_ task: BGProcessingTask) {
        FileLog.shared.addMessage("AdSkipping: background scanning started")

        isPaused = false
        let work = Task { @MainActor in
            scanMissing()
            await waitUntilIdle()
            if !Task.isCancelled {
                task.setTaskCompleted(success: true)
            }
        }

        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                FileLog.shared.addMessage("AdSkipping: background scanning ran out of time")
                work.cancel()
                self?.isPaused = true
                self?.processingTask?.cancel()
                self?.resumeIdleWaiters()
                task.setTaskCompleted(success: false)
                self?.scheduleBackgroundScanningIfNeeded()
            }
        }
    }

    @MainActor
    private func resumeIdleWaiters() {
        idleContinuations.forEach { $0.resume() }
        idleContinuations = []
    }

    @MainActor
    private func waitUntilIdle() async {
        guard processingUuid != nil || !pending.isEmpty else { return }

        await withCheckedContinuation { continuation in
            idleContinuations.append(continuation)
        }
    }
}

private extension String {
    var nilIfEmptyString: String? {
        isEmpty ? nil : self
    }
}

private extension Duration {
    var seconds: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
