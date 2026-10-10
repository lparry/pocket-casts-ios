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
/// finishes, and as a backfill whenever the app launches or comes to the foreground. Finding ads costs
/// money, so it waits until an episode is playing or near the top of Up Next (see `upNextLimit`), and
/// transcribing costs battery, so downloads further down are only transcribed while charging. A background
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
        /// Transcribed, but not near enough the top of Up Next to pay for finding its ads yet
        case waitingForUpNext
        /// Not transcribed, and the phone isn't charging, or is too hot or in Low Power Mode
        case waitingForPower
    }

    /// What a scan of one download should do now
    enum ScanPlan: Equatable {
        /// Transcribe if needed, then find the ads
        case full
        /// Transcribe ahead of time, and find the ads once it's near the top of Up Next
        case transcribeOnly
        case waitingForUpNext
        case waitingForPower
    }

    /// The state of the phone that decides when transcribing is worth the battery
    struct ScanConditions: Equatable {
        var isCharging: Bool
        var isLowPowerMode: Bool
        /// The thermal state is serious or critical
        var isHot: Bool
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

    /// The two halves of a scan, which run side by side, so one episode can be transcribed while another's ads are found
    enum Stage: CaseIterable {
        /// On device, costing battery
        case transcription
        /// Finding the ads in a transcript, costing money, and placing their edges
        case detection
    }

    /// What should happen next to an episode that isn't scanned yet
    enum ScanStep: Equatable {
        case transcribe
        case findAds
        case wait(Status)
    }

    /// The episodes waiting for each stage, in the order they'll be done
    @MainActor
    private var queues: [Stage: [String]] = [.transcription: [], .detection: []]
    /// The episode each stage is working on
    @MainActor
    private var current: [Stage: String] = [:]
    @MainActor
    private var tasks: [Stage: Task<Void, Never>] = [:]
    /// Episodes re-downloaded or rescanned while they were being worked on, which are scanned again when that's done
    @MainActor
    private var rescanWhenDone: Set<String> = []
    /// How long each transcript made this session took, kept for the analysis made from it
    @MainActor
    private var transcriptionTimes: [String: TimeInterval] = [:]
    /// Transcribing and the on-device model are both heavy, so they take turns
    @MainActor
    private let onDeviceWork = OnDeviceWorkGate()
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
    /// Episodes the listener asked to scan, which ignore the Up Next and battery limits
    @MainActor
    private var requested: Set<String> = []
    /// Waits for Up Next or the power state to settle before looking for what to scan
    @MainActor
    private var rescanTask: Task<Void, Never>?

    private struct PlaybackState {
        /// Spans the listener chose to hear with Undo, keyed by episode, so they aren't skipped again this session
        var restoredSpans: [String: Set<AdSpan>] = [:]

        /// An ad the listener asked to hear from the Ad Scanning screen, keyed by episode, which plays through once
        var previewedSpans: [String: AdSpan] = [:]

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

        // What's near the top of Up Next and whether the phone is charging decide what's scanned
        UIDevice.current.isBatteryMonitoringEnabled = true
        for name in [Constants.Notifications.upNextQueueChanged, UIDevice.batteryStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(scanConditionsChanged), name: name, object: nil)
        }

        let transcriptStore = transcriptStore
        Task.detached(priority: .utility) {
            transcriptStore.migrateLegacyFiles()
        }

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

    // MARK: - Limits

    private static let upNextLimitDefaultsKey = "AdSkippingUpNextLimit"
    static let defaultUpNextLimit = 3
    static let upNextLimitOptions = [1, 3, 5, 10]

    /// How many episodes at the top of Up Next have their ads found, as well as the one playing, or nil for every download.
    /// Downloads outside it are only transcribed, and only while charging, so a long list of downloads costs nothing.
    @MainActor
    var upNextLimit: Int? {
        get {
            guard let limit = UserDefaults.standard.object(forKey: Self.upNextLimitDefaultsKey) as? Int else { return Self.defaultUpNextLimit }
            return limit > 0 ? limit : nil
        }
        set {
            UserDefaults.standard.set(newValue ?? 0, forKey: Self.upNextLimitDefaultsKey)
            objectWillChange.send()
            scanMissing()
        }
    }

    /// The episodes whose ads are found automatically: the one playing and the first `limit` of Up Next, or nil for all
    static func detectionWindow(nowPlaying: String?, upNext: [String], limit: Int?) -> Set<String>? {
        guard let limit else { return nil }
        return Set([nowPlaying].compactMap { $0 } + upNext.prefix(limit))
    }

    /// Finding ads costs money, so it only happens in the detection window. Transcribing costs battery, so it happens for any
    /// download while charging, but on battery only for the window, and never when the phone is hot or in Low Power Mode.
    /// A scan the listener asked for ignores all of this.
    static func scanPlan(requested: Bool, inDetectionWindow: Bool, hasTranscript: Bool, conditions: ScanConditions) -> ScanPlan {
        if requested {
            return .full
        }

        let canTranscribe = !conditions.isHot && (conditions.isCharging || (inDetectionWindow && !conditions.isLowPowerMode))
        if inDetectionWindow {
            return hasTranscript || canTranscribe ? .full : .waitingForPower
        }
        if hasTranscript {
            return .waitingForUpNext
        }
        return canTranscribe ? .transcribeOnly : .waitingForPower
    }

    /// Which stage a scan goes to next. A download that's already transcribed goes straight to finding its ads.
    static func nextStep(plan: ScanPlan, hasTranscript: Bool) -> ScanStep {
        switch plan {
        case .full:
            hasTranscript ? .findAds : .transcribe
        case .transcribeOnly:
            hasTranscript ? .wait(.waitingForUpNext) : .transcribe
        case .waitingForUpNext:
            .wait(.waitingForUpNext)
        case .waitingForPower:
            .wait(.waitingForPower)
        }
    }

    @MainActor
    private func nextStep(for episode: BaseEpisode, window: Set<String>?, conditions: ScanConditions) -> ScanStep {
        let hasTranscript = transcriptStore.hasTranscript(for: episode.uuid, audioFileSize: Self.fileSize(of: episode))
        let plan = Self.scanPlan(requested: requested.contains(episode.uuid), inDetectionWindow: window?.contains(episode.uuid) ?? true, hasTranscript: hasTranscript, conditions: conditions)
        return Self.nextStep(plan: plan, hasTranscript: hasTranscript)
    }

    @MainActor
    private func nextStep(for uuid: String) -> ScanStep? {
        dataManager.findBaseEpisode(uuid: uuid).map { nextStep(for: $0, window: currentDetectionWindow(), conditions: Self.currentConditions()) }
    }

    @MainActor
    static func currentConditions() -> ScanConditions {
        let batteryState = UIDevice.current.batteryState
        return ScanConditions(isCharging: batteryState == .charging || batteryState == .full,
                              isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                              isHot: ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue)
    }

    @MainActor
    private func currentDetectionWindow() -> Set<String>? {
        guard let limit = upNextLimit else { return nil }

        let (nowPlaying, upNext) = currentUpNext()
        return Self.detectionWindow(nowPlaying: nowPlaying, upNext: upNext, limit: limit)
    }

    /// The playing episode and Up Next after it, in queue order. Scanning, the detection window and the Ad Zapping list
    /// all go by this, so they can't disagree.
    @MainActor
    private func currentUpNext() -> (nowPlaying: String?, upNext: [String]) {
        let playbackManager = PlaybackManager.shared
        return (playbackManager.currentEpisode?.uuid, playbackManager.queue.allEpisodes(includeNowPlaying: false).map(\.uuid))
    }

    /// The playing episode first, then the rest of Up Next in its order
    static func upNextOrder(nowPlaying: String?, upNext: [String]) -> [String] {
        var seen = Set<String>()
        return ([nowPlaying].compactMap { $0 } + upNext).filter { seen.insert($0).inserted }
    }

    /// Up Next, charging, Low Power Mode and the thermal state can all change often, and from any thread
    @objc private func scanConditionsChanged() {
        Task { @MainActor in
            self.rescanTask?.cancel()
            self.rescanTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }

                self.stopTranscribingIfNoLongerAllowed()
                self.scanMissing()
            }
        }
    }

    /// Stops transcribing ahead of time when the phone comes off the charger, so the battery isn't used for it
    @MainActor
    private func stopTranscribingIfNoLongerAllowed() {
        guard let uuid = current[.transcription], case .wait = nextStep(for: uuid) else { return }

        FileLog.shared.addMessage("AdSkipping: stopped transcribing \(uuid), since the phone isn't charging")
        tasks[.transcription]?.cancel()
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
            let episodeUuids = Set(queues.values.joined().filter { uuid in
                dataManager.findEpisode(uuid: uuid)?.podcastUuid == podcastUuid
            })
            for stage in Stage.allCases {
                queues[stage]?.removeAll { episodeUuids.contains($0) }
            }
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
        guard let (spans, kinds, restored) = skippableSpans(in: episode, at: time) else { return nil }
        return Self.adSkip(in: spans, at: time, skipping: kinds, restored: restored)
    }

    /// When the next ad starts, if it's after `time` and no more than `within` away
    func nextAdStart(in episode: BaseEpisode, after time: TimeInterval, within: TimeInterval) -> TimeInterval? {
        guard let (spans, kinds, restored) = skippableSpans(in: episode, at: time) else { return nil }
        return spans.first { $0.start > time && $0.start - time <= within && kinds.contains($0.kind) && !restored.contains($0) }?.start
    }

    private func skippableSpans(in episode: BaseEpisode, at time: TimeInterval) -> ([AdSpan], Set<AdSpan.Kind>, Set<AdSpan>)? {
        guard FeatureFlag.autoAdSkip.enabled, isScanning(episode), let analysis = currentAnalysis(for: episode), !analysis.isSuspect, !analysis.spans.isEmpty else {
            return nil
        }

        let (restored, skippedKinds) = playbackState.withLock { state in
            var restored = state.restoredSpans[episode.uuid] ?? []
            state.previewedSpans[episode.uuid] = Self.preview(state.previewedSpans[episode.uuid], at: time)
            if let previewed = state.previewedSpans[episode.uuid] {
                restored.insert(previewed)
            }
            return (restored, state.skippedKinds)
        }
        return (analysis.spans, skippedKinds, restored)
    }

    /// The previewed ad, until playback reaches its end, after which it's skipped like any other
    static func preview(_ span: AdSpan?, at time: TimeInterval) -> AdSpan? {
        guard let span, time < span.end else { return nil }
        return span
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

    /// How long after an ad ends a skip back over it still counts as wanting to hear it
    static let unzapWindow: TimeInterval = 120

    /// Lets the ads a skip back lands in or jumps back over play, like Undo on the toast, since the listener is often
    /// using a car or headphones and never sees the toast. Returns the ads it un-zapped.
    @discardableResult
    func unzapAds(in episode: BaseEpisode, skippingBackFrom from: TimeInterval, to: TimeInterval) -> [AdSpan] {
        guard let (spans, kinds, restored) = skippableSpans(in: episode, at: to) else { return [] }

        let unzapped = Self.adsToUnzap(in: spans, from: from, to: to, skipping: kinds, restored: restored)
        if !unzapped.isEmpty {
            restore(unzapped, in: episode.uuid)
        }
        return unzapped
    }

    /// The ads that would be zapped which a skip back from `from` to `to` lands in or jumps back over. Only ads that ended
    /// within `window` of `from` count, so rewinding a long way doesn't un-zap every ad along the way.
    static func adsToUnzap(in spans: [AdSpan], from: TimeInterval, to: TimeInterval, skipping kinds: Set<AdSpan.Kind>, restored: Set<AdSpan>, window: TimeInterval = unzapWindow) -> [AdSpan] {
        guard to < from else { return [] }

        return spans.filter { span in
            kinds.contains(span.kind)
                && !restored.contains(span)
                // Behind where playback was, and ending after where it lands, so it's landed in or jumped over
                && span.start < from
                && span.end > to
                && from - span.end <= window
        }
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
    /// A scan the listener asked for is `requested`, and ignores the Up Next and battery limits.
    @MainActor
    func enqueue(_ episodeUuid: String, force: Bool = false, first: Bool = false, requested isRequested: Bool = false) {
        guard FeatureFlag.autoAdSkip.enabled else { return }
        guard let episode = dataManager.findBaseEpisode(uuid: episodeUuid), isScanning(episode) else { return }

        // Being worked on already, maybe for a file that's just been replaced, so go again once that's done
        if current.values.contains(episodeUuid) {
            if force {
                rescanWhenDone.insert(episodeUuid)
                if isRequested {
                    requested.insert(episodeUuid)
                }
            }
            return
        }

        guard force || (currentAnalysis(for: episode) == nil && !hasKnownFailure(episode, classifiers: Self.classifiersKey(classifiers))) else { return }

        retryableFailures.remove(episodeUuid)
        if isRequested {
            requested.insert(episodeUuid)
        }
        // Whether it waits is decided when its turn comes, since Up Next and the battery may change before then
        let hasTranscript = transcriptStore.hasTranscript(for: episodeUuid, audioFileSize: Self.fileSize(of: episode))
        route(episodeUuid, to: hasTranscript ? .findAds : .transcribe, first: first)
        processNextIfNeeded()
    }

    /// Moves an episode into the queue for its next stage, out of any other, or marks it as waiting
    @MainActor
    private func route(_ uuid: String, to step: ScanStep, first: Bool) {
        for stage in Stage.allCases {
            queues[stage]?.removeAll { $0 == uuid }
        }

        let stage: Stage
        switch step {
        case .transcribe:
            stage = .transcription
        case .findAds:
            stage = .detection
        case .wait(let status):
            statuses[uuid] = status
            return
        }

        if first {
            queues[stage]?.insert(uuid, at: 0)
        } else {
            queues[stage]?.append(uuid)
        }
        statuses[uuid] = .queued
    }

    /// Queues every downloaded episode that hasn't been scanned for the file on disk, playing and Up Next first, as far as
    /// the Up Next and battery limits allow. The rest are marked as waiting.
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
        let episodesByUuid = Dictionary(episodes.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        let skipped = Set(episodes.filter { currentAnalysis(for: $0) != nil || hasKnownFailure($0, classifiers: classifiersKey) }.map(\.uuid))
        let (nowPlaying, upNext) = currentUpNext()
        let ordered = Self.scanOrder(downloaded: episodes.map(\.uuid), upNext: Self.upNextOrder(nowPlaying: nowPlaying, upNext: upNext))
        let window = currentDetectionWindow()
        let conditions = Self.currentConditions()

        // Collected and published once, since there can be hundreds of downloads
        var newStatuses = statuses
        var toScan: [Stage: [String]] = [.transcription: [], .detection: []]
        let working = Set(current.values)
        for uuid in ordered {
            guard !working.contains(uuid), !skipped.contains(uuid), let episode = episodesByUuid[uuid] else { continue }
            if case .failed = statuses[uuid], !retryableFailures.contains(uuid) {
                continue
            }

            switch nextStep(for: episode, window: window, conditions: conditions) {
            case .transcribe:
                toScan[.transcription]?.append(uuid)
                newStatuses[uuid] = .queued
            case .findAds:
                toScan[.detection]?.append(uuid)
                newStatuses[uuid] = .queued
            case .wait(let status):
                newStatuses[uuid] = status
            }
        }

        // Everything just routed goes first, in scan order, ahead of anything queued some other way
        let routed = Set(toScan.values.joined())
        let waiting = Set(newStatuses.filter { $0.value == .waitingForUpNext || $0.value == .waitingForPower }.keys)
        for stage in Stage.allCases {
            queues[stage] = (toScan[stage] ?? []) + (queues[stage] ?? []).filter { !routed.contains($0) && !waiting.contains($0) }
        }
        if newStatuses != statuses {
            statuses = newStatuses
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

    /// Every downloaded episode in the order they're scanned: the one playing, then Up Next, then the rest, most recently
    /// downloaded first
    @MainActor
    func downloadedEpisodesInScanOrder() -> [BaseEpisode] {
        let episodes = downloadedEpisodes()
        let episodesByUuid = Dictionary(episodes.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        let (nowPlaying, upNext) = currentUpNext()
        return Self.scanOrder(downloaded: episodes.map(\.uuid), upNext: Self.upNextOrder(nowPlaying: nowPlaying, upNext: upNext))
            .compactMap { episodesByUuid[$0] }
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

    /// Plays from just before an ad, and lets it play through once, so the listener can hear what was found
    @MainActor
    func play(_ span: AdSpan, in episode: BaseEpisode) {
        playbackState.withLock { $0.previewedSpans[episode.uuid] = span }

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
    private var isIdle: Bool {
        current.isEmpty && queues.values.allSatisfy(\.isEmpty)
    }

    /// Starts each stage on its next episode, if it's free
    @MainActor
    private func processNextIfNeeded() {
        for stage in Stage.allCases {
            startNext(stage)
        }

        updateBackgroundTask()
        if isIdle {
            resumeIdleWaiters()
        }
    }

    @MainActor
    private func startNext(_ stage: Stage) {
        guard current[stage] == nil, !isPaused, let uuid = queues[stage]?.first else { return }

        queues[stage]?.removeFirst()
        current[stage] = uuid
        tasks[stage] = Task {
            switch stage {
            case .transcription:
                await transcribe(uuid)
            case .detection:
                await findAds(uuid)
            }

            current[stage] = nil
            tasks[stage] = nil
            if rescanWhenDone.remove(uuid) != nil {
                enqueue(uuid, force: true, first: true)
            }
            processNextIfNeeded()
        }
    }

    /// Transcribes an episode, then hands it to the detection stage if its ads are due to be found
    @MainActor
    private func transcribe(_ uuid: String) async {
        // Decided now rather than when queued, since Up Next and the battery may have changed since
        switch nextStep(for: uuid) {
        case .wait(let status):
            statuses[uuid] = status
            return
        case .findAds:
            route(uuid, to: .findAds, first: requested.contains(uuid))
            return
        case .transcribe, nil:
            break
        }

        retryableFailures.remove(uuid)
        let failureKey = failureKey(for: uuid)

        do {
            try await makeTranscript(uuid)
            FileLog.shared.addMessage("AdSkipping: transcribed \(uuid)")

            // It may have moved up Up Next while it was being transcribed
            switch nextStep(for: uuid) {
            case .findAds:
                route(uuid, to: .findAds, first: requested.contains(uuid))
            default:
                statuses[uuid] = .waitingForUpNext
            }
        } catch where Task.isCancelled {
            // Interrupted, not failed, so pick it up again next time
            queues[.transcription]?.insert(uuid, at: 0)
            statuses[uuid] = .queued
            FileLog.shared.addMessage("AdSkipping: interrupted while transcribing \(uuid)")
        } catch {
            scanFailed(uuid, error: error, key: failureKey)
        }
    }

    /// Finds the ads in an episode's transcript, and places their edges
    @MainActor
    private func findAds(_ uuid: String) async {
        switch nextStep(for: uuid) {
        case .wait(let status):
            statuses[uuid] = status
            return
        case .transcribe:
            route(uuid, to: .transcribe, first: true)
            return
        case .findAds, nil:
            break
        }

        retryableFailures.remove(uuid)
        let failureKey = failureKey(for: uuid)

        do {
            guard let result = try await detectAds(uuid) else {
                // The transcript has gone, maybe with a re-download, so it needs making again
                route(uuid, to: .transcribe, first: true)
                return
            }

            failureStore.remove(uuid)
            requested.remove(uuid)
            statuses[uuid] = .finished(adCount: result.spans.count, classifier: result.classifier)
            FileLog.shared.addMessage("AdSkipping: \(result.classifier) found \(result.spans.count) ads in \(uuid)")
        } catch where Task.isCancelled {
            queues[.detection]?.insert(uuid, at: 0)
            statuses[uuid] = .queued
            FileLog.shared.addMessage("AdSkipping: interrupted while finding ads in \(uuid)")
        } catch {
            scanFailed(uuid, error: error, key: failureKey)
        }
    }

    /// Captured before a stage starts, so a failure is tied to the file and classifiers it happened with
    @MainActor
    private func failureKey(for uuid: String) -> (classifiers: String, fileSize: UInt64?) {
        (Self.classifiersKey(classifiers), dataManager.findBaseEpisode(uuid: uuid).flatMap { Self.fileSize(of: $0) })
    }

    @MainActor
    private func scanFailed(_ uuid: String, error: Error, key: (classifiers: String, fileSize: UInt64?)) {
        requested.remove(uuid)
        statuses[uuid] = .failed(error.localizedDescription)
        if AdSkippingError.isRetryable(error) {
            retryableFailures.insert(uuid)
        } else if AdSkippingError.isPermanent(error) {
            let failure = AdScanFailure(audioFileSize: key.fileSize, classifiers: key.classifiers, message: error.localizedDescription, failedAt: Date())
            try? failureStore.save(failure, for: uuid)
        }
        FileLog.shared.addMessage("AdSkipping: failed to scan \(uuid): \(error)")
    }

    /// Transcribing a long episode takes a while, so ask for time to finish if the app is backgrounded while either stage
    /// is working. If that time runs out, both stop and are picked up again later, so iOS doesn't end the app.
    @MainActor
    private func updateBackgroundTask() {
        if current.isEmpty {
            endBackgroundTask()
        } else if backgroundTaskId == .invalid {
            backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "AdSkipping") { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }

                    FileLog.shared.addMessage("AdSkipping: ran out of background time, pausing until the app is next active")
                    self.isPaused = true
                    self.cancelWork()
                    self.scheduleBackgroundScanningIfNeeded()
                    self.endBackgroundTask()
                }
            }
        }
    }

    @MainActor
    private func cancelWork() {
        tasks.values.forEach { $0.cancel() }
    }

    @MainActor
    private func endBackgroundTask() {
        guard backgroundTaskId != .invalid else { return }

        UIApplication.shared.endBackgroundTask(backgroundTaskId)
        backgroundTaskId = .invalid
    }

    /// Transcribes the download and saves the transcript for the detection stage
    @MainActor
    private func makeTranscript(_ uuid: String) async throws {
        guard let episode = dataManager.findBaseEpisode(uuid: uuid), episode.downloaded(pathFinder: DownloadManager.shared) else {
            throw AdSkippingError.notDownloaded
        }
        // Nothing is scanned without a key, so there's no point transcribing either
        guard !classifiers.isEmpty else {
            throw AdSkippingError.noClassifier
        }
        guard let transcriber = transcriberProvider() else {
            throw AdSkippingError.transcriptionUnavailable
        }

        let fileURL = URL(fileURLWithPath: episode.pathToDownloadedFile(pathFinder: DownloadManager.shared))
        let fileSize = Self.fileSize(of: episode)
        let clock = ContinuousClock()

        statuses[uuid] = .transcribing(progress: nil, timeLeft: nil)
        await onDeviceWork.acquire()
        defer {
            onDeviceWork.release()
        }

        let audioDuration = Self.audioDuration(of: fileURL)
        let started = clock.now
        // Podcasts don't record their language, so assume they're in the listener's
        let transcript = try await transcriber.transcribe(fileURL: fileURL, locale: Locale.current) { [weak self] progress in
            Task { @MainActor in
                self?.transcriptionProgressed(uuid, progress: progress, since: started, clock: clock)
            }
        }
        try Task.checkCancellation()

        transcriptionTimes[uuid] = (clock.now - started).seconds
        // Saved even when empty, so it isn't transcribed again only to come out empty
        try? transcriptStore.save(transcript, for: uuid, audioFileSize: fileSize, audioDuration: audioDuration)

        guard !transcript.isEmpty else {
            throw AdSkippingError.emptyTranscript
        }
    }

    /// Finds the ads in the saved transcript, or returns nil if there isn't one for the file on disk
    @MainActor
    private func detectAds(_ uuid: String) async throws -> (spans: [AdSpan], classifier: String)? {
        guard let episode = dataManager.findBaseEpisode(uuid: uuid), episode.downloaded(pathFinder: DownloadManager.shared) else {
            throw AdSkippingError.notDownloaded
        }

        // The on-device model waits for the transcription stage, rather than running alongside it
        let onDeviceWork = onDeviceWork
        let classifiers = classifiers.map { classifier -> AdClassifier in
            classifier.runsOnDevice ? TakingTurnsClassifier(base: classifier, gate: onDeviceWork) : classifier
        }
        guard !classifiers.isEmpty else {
            throw AdSkippingError.noClassifier
        }

        let fileURL = URL(fileURLWithPath: episode.pathToDownloadedFile(pathFinder: DownloadManager.shared))
        let fileSize = Self.fileSize(of: episode)
        let clock = ContinuousClock()
        var timings = AdScanTimings()

        statuses[uuid] = .classifying
        guard let saved = await Self.loadTranscript(episodeUuid: uuid, audioFileSize: fileSize, from: transcriptStore) else { return nil }
        let transcript = saved.segments
        timings.audioDuration = saved.audioDuration
        // Only known when it was transcribed this session
        timings.transcription = transcriptionTimes.removeValue(forKey: uuid)

        guard !transcript.isEmpty else {
            throw AdSkippingError.emptyTranscript
        }

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
        let snapped = await AudioBoundarySnapper.snap(refinedSpans, words: words, fileURL: fileURL)
        let snappedSpans = snapped.spans
        timings.audioSnapping = (clock.now - started).seconds
        timings.snappedEdges = snapped.movedEdges
        timings.edgeCount = refinedSpans.count * 2
        timings.audioUnreadable = !snapped.couldReadFile
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

    /// A long transcript takes a moment to read, so it's read off the main thread
    @concurrent
    private static func loadTranscript(episodeUuid: String, audioFileSize: UInt64?, from transcriptStore: TranscriptStore) async -> (segments: [TranscriptSegment], audioDuration: TimeInterval?)? {
        transcriptStore.transcript(for: episodeUuid, audioFileSize: audioFileSize)
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
        // Downloads waiting for power are transcribed by the task, which only runs while charging
        guard !isIdle || statuses.values.contains(.waitingForPower) else { return }

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
                self?.cancelWork()
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
        guard !isIdle else { return }

        await withCheckedContinuation { continuation in
            idleContinuations.append(continuation)
        }
    }
}

/// Lets one heavy on-device job run at a time, first come first served. Transcribing and the on-device model each use a
/// lot of memory and heat, so they take turns rather than running together.
@MainActor
final class OnDeviceWorkGate {
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isBusy else {
            isBusy = true
            return
        }
        // Released straight to the next in line, so it stays busy
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// An on-device classifier that waits its turn with transcription
private struct TakingTurnsClassifier: AdClassifier {
    let base: AdClassifier
    let gate: OnDeviceWorkGate

    var identifier: String {
        base.identifier
    }

    var runsOnDevice: Bool {
        true
    }

    func adSpans(in transcript: [TranscriptSegment], context: AdClassificationContext) async throws -> [AdSpan] {
        await gate.acquire()
        defer {
            Task { @MainActor in gate.release() }
        }
        return try await base.adSpans(in: transcript, context: context)
    }

    func boundaryWordIndices(for requests: [AdBoundaryRequest]) async throws -> [Int?] {
        await gate.acquire()
        defer {
            Task { @MainActor in gate.release() }
        }
        return try await base.boundaryWordIndices(for: requests)
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
