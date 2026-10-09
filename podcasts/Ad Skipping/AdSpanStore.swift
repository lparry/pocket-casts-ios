import Foundation
import os
import PocketCastsUtils

/// Persists each episode's `EpisodeAdAnalysis` as JSON in Application Support.
///
/// Playback asks for spans on every progress tick, so lookups are served from memory after the first read.
final class AdSpanStore {
    private let directory: URL
    private let fileManager: FileManager
    private let cache = OSAllocatedUnfairLock<[String: EpisodeAdAnalysis?]>(initialState: [:])

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.directory = directory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AdSkipping", isDirectory: true)
    }

    func analysis(for episodeUuid: String) -> EpisodeAdAnalysis? {
        if let cached = cache.withLock({ $0[episodeUuid] }) {
            return cached
        }

        let analysis = load(episodeUuid)
        cache.withLock { $0[episodeUuid] = .some(analysis) }
        return analysis
    }

    func save(_ analysis: EpisodeAdAnalysis) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(analysis)
        try data.write(to: fileURL(for: analysis.episodeUuid), options: .atomic)
        cache.withLock { $0[analysis.episodeUuid] = .some(analysis) }
    }

    func remove(_ episodeUuid: String) {
        try? fileManager.removeItem(at: fileURL(for: episodeUuid))
        cache.withLock { $0[episodeUuid] = .some(nil) }
    }

    /// Deletes the analyses of episodes that aren't downloaded any more
    func removeAll(except episodeUuids: Set<String>) {
        let files = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            let episodeUuid = file.deletingPathExtension().lastPathComponent
            guard !episodeUuids.contains(episodeUuid) else { continue }

            remove(episodeUuid)
        }
    }

    private func load(_ episodeUuid: String) -> EpisodeAdAnalysis? {
        guard let data = try? Data(contentsOf: fileURL(for: episodeUuid)) else { return nil }

        guard let analysis = try? JSONDecoder().decode(EpisodeAdAnalysis.self, from: data), Self.isCurrent(analysis) else {
            FileLog.shared.addMessage("AdSpanStore: discarding unreadable analysis for \(episodeUuid)")
            return nil
        }

        return analysis
    }

    /// Version 2 analyses could fall back to the on-device model when OpenRouter couldn't be reached, so only those found by
    /// OpenRouter are kept. The rest are scanned again, reusing their transcripts.
    static func isCurrent(_ analysis: EpisodeAdAnalysis) -> Bool {
        analysis.version == EpisodeAdAnalysis.currentVersion
            || (analysis.version == 2 && analysis.classifier.hasPrefix(OpenRouterAdClassifier.identifierPrefix))
    }

    private func fileURL(for episodeUuid: String) -> URL {
        directory.appendingPathComponent(episodeUuid).appendingPathExtension("json")
    }
}

/// Why a download couldn't be scanned, kept across launches so a scan that will only fail again isn't repeated and paid for
struct AdScanFailure: Codable, Equatable {
    /// The size of the download that failed, so a re-download is tried again
    let audioFileSize: UInt64?
    /// The classifiers that were tried, so changing the model or key tries again
    let classifiers: String
    let message: String
    let failedAt: Date

    /// Whether scanning this file with these classifiers would only fail the same way again
    func matches(audioFileSize: UInt64?, classifiers: String) -> Bool {
        self.audioFileSize == audioFileSize && self.classifiers == classifiers
    }
}

/// Persists each episode's `AdScanFailure` as JSON in Application Support
final class AdScanFailureStore {
    private let directory: URL
    private let fileManager: FileManager

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.directory = directory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AdSkipping/Failures", isDirectory: true)
    }

    func failure(for episodeUuid: String) -> AdScanFailure? {
        guard let data = try? Data(contentsOf: fileURL(for: episodeUuid)) else { return nil }
        return try? JSONDecoder().decode(AdScanFailure.self, from: data)
    }

    func save(_ failure: AdScanFailure, for episodeUuid: String) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(failure).write(to: fileURL(for: episodeUuid), options: .atomic)
    }

    func remove(_ episodeUuid: String) {
        try? fileManager.removeItem(at: fileURL(for: episodeUuid))
    }

    /// Deletes the failures of episodes that aren't downloaded any more
    func removeAll(except episodeUuids: Set<String>) {
        let files = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" && !episodeUuids.contains(file.deletingPathExtension().lastPathComponent) {
            try? fileManager.removeItem(at: file)
        }
    }

    private func fileURL(for episodeUuid: String) -> URL {
        directory.appendingPathComponent(episodeUuid).appendingPathExtension("json")
    }
}

/// Keeps each download's transcript, so a rescan only reruns the classifier and never the slow transcription
final class TranscriptStore {
    /// Bump when the transcript itself changes, which is the only time a download needs transcribing again
    static let formatVersion = 1

    private struct StoredTranscript: Codable {
        let formatVersion: Int
        let audioFileSize: UInt64?
        let audioDuration: TimeInterval?
        let segments: [TranscriptSegment]
    }

    private let directory: URL
    private let fileManager: FileManager

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.directory = directory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AdSkipping/Transcripts", isDirectory: true)
    }

    /// The saved transcript, if it was made from a file of this size in the current format
    func transcript(for episodeUuid: String, audioFileSize: UInt64?) -> (segments: [TranscriptSegment], audioDuration: TimeInterval?)? {
        guard let data = try? Data(contentsOf: fileURL(for: episodeUuid)),
              let stored = try? JSONDecoder().decode(StoredTranscript.self, from: data),
              stored.formatVersion == Self.formatVersion,
              stored.audioFileSize == audioFileSize
        else {
            return nil
        }
        return (stored.segments, stored.audioDuration)
    }

    func save(_ segments: [TranscriptSegment], for episodeUuid: String, audioFileSize: UInt64?, audioDuration: TimeInterval?) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let stored = StoredTranscript(formatVersion: Self.formatVersion, audioFileSize: audioFileSize, audioDuration: audioDuration, segments: segments)
        try JSONEncoder().encode(stored).write(to: fileURL(for: episodeUuid), options: .atomic)
    }

    /// Deletes the transcripts of episodes that aren't downloaded any more
    func removeAll(except episodeUuids: Set<String>) {
        let files = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" && !episodeUuids.contains(file.deletingPathExtension().lastPathComponent) {
            try? fileManager.removeItem(at: file)
        }
    }

    private func fileURL(for episodeUuid: String) -> URL {
        directory.appendingPathComponent(episodeUuid).appendingPathExtension("json")
    }
}
