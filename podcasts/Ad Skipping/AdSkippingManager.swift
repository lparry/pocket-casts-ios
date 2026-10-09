import Combine
import Foundation
import os
import PocketCastsDataModel
import PocketCastsUtils
import UIKit

/// Finds the ads in downloaded episodes and tells playback which ones to skip.
///
/// When an episode finishes downloading, the local file is transcribed on device and the
/// timestamped transcript goes to an `AdClassifier`: OpenRouter when the listener has saved a key,
/// otherwise Apple's on-device model, which is also the fallback if OpenRouter fails. The resulting spans are in the timeline of
/// that download, so they're only used while it's still the file on disk.
///
/// Processing runs on the main actor, but playback reads spans from the progress tick, so that state is behind a lock.
final class AdSkippingManager: ObservableObject, @unchecked Sendable {
    static let shared = AdSkippingManager()

    enum Status: Equatable {
        case queued
        case transcribing
        case classifying
        case finished(adCount: Int, classifier: String)
        case failed(String)
    }

    /// The status of each episode processed since launch
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

    private struct PlaybackState {
        /// Spans the listener chose to hear with Undo, keyed by episode, so they aren't skipped again this session
        var restoredSpans: [String: Set<AdSpan>] = [:]

        /// Whether each episode's stored analysis was made from the file that's on disk now
        var analysisMatchesFile: [String: Bool] = [:]
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

    @MainActor
    func setup() {
        NotificationCenter.default.addObserver(self, selector: #selector(episodeDownloaded(_:)), name: Constants.Notifications.episodeDownloaded, object: nil)
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
            UserDefaults.standard.set(model.isEmpty ? nil : model, forKey: Self.modelDefaultsKey)
            objectWillChange.send()
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

    // MARK: - Playback

    /// The ad to skip at `time`, if any
    func adToSkip(in episode: BaseEpisode, at time: TimeInterval) -> AdSpan? {
        guard FeatureFlag.autoAdSkip.enabled,
              let analysis = store.analysis(for: episode.uuid),
              !analysis.spans.isEmpty,
              analysisMatchesDownloadedFile(analysis, episode: episode)
        else {
            return nil
        }

        let restored = playbackState.withLock { $0.restoredSpans[episode.uuid] } ?? []
        // Don't bother skipping the last moment of an ad
        return analysis.spans.first { $0.contains(time) && $0.end - time > 1 && !restored.contains($0) }
    }

    /// Stops `span` being skipped again until the next launch
    func restore(_ span: AdSpan, in episodeUuid: String) {
        playbackState.withLock { _ = $0.restoredSpans[episodeUuid, default: []].insert(span) }
    }

    /// Spans only line up with the download that was transcribed, never with a stream
    private func analysisMatchesDownloadedFile(_ analysis: EpisodeAdAnalysis, episode: BaseEpisode) -> Bool {
        guard episode.downloaded(pathFinder: DownloadManager.shared) else { return false }

        if let matches = playbackState.withLock({ $0.analysisMatchesFile[episode.uuid] }) {
            return matches
        }

        let matches = analysis.audioFileSize == Self.fileSize(of: episode)
        playbackState.withLock { $0.analysisMatchesFile[episode.uuid] = matches }
        return matches
    }

    private func forgetFileMatch(for episodeUuid: String) {
        playbackState.withLock { $0.analysisMatchesFile[episodeUuid] = nil }
    }

    // MARK: - Processing

    @MainActor
    @objc private func episodeDownloaded(_ notification: Notification) {
        guard FeatureFlag.autoAdSkip.enabled, let uuid = notification.object as? String else { return }

        // A new download can have different ads inserted, so always start over
        forgetFileMatch(for: uuid)
        enqueue(uuid, force: true)
    }

    /// Queues an episode for analysis. Without `force`, episodes that already have an analysis are skipped.
    @MainActor
    func enqueue(_ episodeUuid: String, force: Bool = false) {
        guard force || store.analysis(for: episodeUuid) == nil else { return }
        guard processingUuid != episodeUuid, !pending.contains(episodeUuid) else { return }

        pending.append(episodeUuid)
        statuses[episodeUuid] = .queued
        processNextIfNeeded()
    }

    @MainActor
    func removeAnalysis(for episodeUuid: String) {
        store.remove(episodeUuid)
        forgetFileMatch(for: episodeUuid)
        statuses[episodeUuid] = nil
        analysesVersion += 1
    }

    @MainActor
    private func processNextIfNeeded() {
        guard processingUuid == nil, !pending.isEmpty else { return }

        let uuid = pending.removeFirst()
        processingUuid = uuid

        Task {
            await process(uuid)
            processingUuid = nil
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
        } catch {
            statuses[uuid] = .failed(error.localizedDescription)
            FileLog.shared.addMessage("AdSkipping: failed to analyze \(uuid): \(error)")
        }
    }

    @MainActor
    private func analyze(_ uuid: String) async throws -> (spans: [AdSpan], classifier: String) {
        guard let episode = dataManager.findEpisode(uuid: uuid), episode.downloaded(pathFinder: DownloadManager.shared) else {
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
        guard !transcript.isEmpty else {
            throw AdSkippingError.emptyTranscript
        }

        statuses[uuid] = .classifying
        let context = AdClassificationContext(podcastTitle: episode.parentPodcast(dataManager: dataManager)?.title, episodeTitle: episode.title, duration: episode.duration)
        let (spans, classifier) = try await classify(transcript, context: context, using: classifiers)

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
}

private extension String {
    var nilIfEmptyString: String? {
        isEmpty ? nil : self
    }
}
