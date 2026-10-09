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
/// transcribed on device and the timestamped transcript goes to an `AdClassifier`: OpenRouter when
/// the listener has saved a key, otherwise Apple's on-device model, which is also the fallback if
/// OpenRouter fails. The resulting spans are in the timeline of that download, so they're only used
/// while it's still the file on disk.
///
/// Processing runs on the main actor, but playback reads spans from the progress tick, so that state is behind a lock.
final class AdSkippingManager: ObservableObject, @unchecked Sendable {
    static let shared = AdSkippingManager()

    static let backgroundTaskIdentifier = "au.com.shiftyjelly.podcasts.AdSkipping"

    enum Status: Equatable {
        case queued
        case transcribing
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

    private let transcriberProvider: () -> EpisodeTranscriber?
    private let classifiersProvider: (_ openRouterApiKey: String?, _ openRouterModel: String) -> [AdClassifier]
    private let dataManager: DataManager

    @MainActor
    private var pending: [String] = []
    @MainActor
    private var processingUuid: String?
    @MainActor
    private var processingTask: Task<Void, Never>?
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
    }

    private let playbackState = OSAllocatedUnfairLock(initialState: PlaybackState())

    init(store: AdSpanStore = AdSpanStore(),
         dataManager: DataManager = .shared,
         transcriberProvider: (() -> EpisodeTranscriber?)? = nil,
         classifiersProvider: ((_ openRouterApiKey: String?, _ openRouterModel: String) -> [AdClassifier])? = nil) {
        self.store = store
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

    private static func defaultClassifiers(openRouterApiKey: String?, openRouterModel: String) -> [AdClassifier] {
        var classifiers: [AdClassifier] = []
        if let openRouterApiKey {
            classifiers.append(OpenRouterAdClassifier(apiKey: openRouterApiKey, model: openRouterModel))
        }
        if #available(iOS 26, *), FoundationModelsAdClassifier.isAvailable {
            classifiers.append(FoundationModelsAdClassifier())
        }
        return classifiers
    }

    /// Episodes that failed may work with different classifiers, so give them another go
    @MainActor
    private func classifiersChanged() {
        statuses = statuses.filter { _, status in
            if case .failed = status { return false }
            return true
        }
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

    // MARK: - Playback

    /// The ad to skip at `time`, if any
    func adToSkip(in episode: BaseEpisode, at time: TimeInterval) -> AdSpan? {
        guard FeatureFlag.autoAdSkip.enabled, let analysis = currentAnalysis(for: episode), !analysis.spans.isEmpty else {
            return nil
        }

        let (restored, skippedKinds) = playbackState.withLock { ($0.restoredSpans[episode.uuid] ?? [], $0.skippedKinds) }
        return Self.adToSkip(in: analysis.spans, at: time, skipping: skippedKinds, restored: restored)
    }

    static func adToSkip(in spans: [AdSpan], at time: TimeInterval, skipping kinds: Set<AdSpan.Kind>, restored: Set<AdSpan>) -> AdSpan? {
        // Don't bother skipping the last moment of an ad
        spans.first { $0.contains(time) && $0.end - time > 1 && kinds.contains($0.kind) && !restored.contains($0) }
    }

    /// Stops `span` being skipped again until the next launch
    func restore(_ span: AdSpan, in episodeUuid: String) {
        playbackState.withLock { _ = $0.restoredSpans[episodeUuid, default: []].insert(span) }
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
        guard force || !isScanned(episodeUuid) else { return }

        pending.removeAll { $0 == episodeUuid }
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
    /// Episodes that failed since launch are left alone unless `includingFailed`, so a permanent failure isn't retried on every foreground.
    @MainActor
    func scanMissing(includingFailed: Bool = false) {
        guard FeatureFlag.autoAdSkip.enabled else { return }

        let episodes = downloadedEpisodes()
        let scanned = Set(episodes.filter { currentAnalysis(for: $0) != nil }.map(\.uuid))
        let upNext = PlaybackManager.shared.queue.allEpisodes(includeNowPlaying: true).map(\.uuid)
        let ordered = Self.scanOrder(downloaded: episodes.map(\.uuid), upNext: upNext)

        let toScan = ordered.filter { uuid in
            guard uuid != processingUuid, !scanned.contains(uuid) else { return false }
            if case .failed = statuses[uuid] {
                return includingFailed
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

    @MainActor
    private func isScanned(_ episodeUuid: String) -> Bool {
        guard let episode = dataManager.findBaseEpisode(uuid: episodeUuid) else { return false }
        return currentAnalysis(for: episode) != nil
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
        // Transcribing a long episode takes a while, so ask for time to finish if the app is backgrounded
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "AdSkipping")
        defer {
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
            }
        }

        do {
            let (spans, classifier) = try await analyze(uuid)
            statuses[uuid] = .finished(adCount: spans.count, classifier: classifier)
            FileLog.shared.addMessage("AdSkipping: \(classifier) found \(spans.count) ads in \(uuid)")
        } catch where Task.isCancelled {
            // Interrupted, not failed, so pick it up again next time
            pending.insert(uuid, at: 0)
            statuses[uuid] = .queued
            FileLog.shared.addMessage("AdSkipping: interrupted while scanning \(uuid)")
        } catch {
            statuses[uuid] = .failed(error.localizedDescription)
            FileLog.shared.addMessage("AdSkipping: failed to scan \(uuid): \(error)")
        }
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

        guard let transcriber = transcriberProvider() else {
            throw AdSkippingError.transcriptionUnavailable
        }

        let fileURL = URL(fileURLWithPath: episode.pathToDownloadedFile(pathFinder: DownloadManager.shared))
        let fileSize = Self.fileSize(of: episode)

        statuses[uuid] = .transcribing
        // Podcasts don't record their language, so assume they're in the listener's
        let transcript = try await transcriber.transcribe(fileURL: fileURL, locale: Locale.current)
        try Task.checkCancellation()
        guard !transcript.isEmpty else {
            throw AdSkippingError.emptyTranscript
        }

        statuses[uuid] = .classifying
        let podcastTitle = (episode as? Episode)?.parentPodcast(dataManager: dataManager)?.title
        let context = AdClassificationContext(podcastTitle: podcastTitle, episodeTitle: episode.title, duration: episode.duration)
        let (spans, classifier) = try await classify(transcript, context: context, using: classifiers)
        try Task.checkCancellation()

        let analysis = EpisodeAdAnalysis(version: EpisodeAdAnalysis.currentVersion,
                                         episodeUuid: uuid,
                                         analyzedAt: Date(),
                                         classifier: classifier.identifier,
                                         audioFileSize: fileSize,
                                         transcriptSegmentCount: transcript.count,
                                         spans: spans)
        try store.save(analysis)
        forgetFileMatch(for: uuid)
        analysesVersion += 1

        return (spans, classifier.identifier)
    }

    /// Tries each classifier in turn until one succeeds
    @MainActor
    private func classify(_ transcript: [TranscriptSegment], context: AdClassificationContext, using classifiers: [AdClassifier]) async throws -> ([AdSpan], AdClassifier) {
        var lastError: Error = AdSkippingError.noClassifier
        for classifier in classifiers {
            do {
                return (try await classifier.adSpans(in: transcript, context: context), classifier)
            } catch {
                try Task.checkCancellation()
                FileLog.shared.addMessage("AdSkipping: \(classifier.identifier) failed, trying the next classifier: \(error)")
                lastError = error
            }
        }
        throw lastError
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
