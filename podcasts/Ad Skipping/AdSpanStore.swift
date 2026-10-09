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

    /// Every stored analysis, newest first
    func allAnalyses() -> [EpisodeAdAnalysis] {
        let files = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { analysis(for: $0.deletingPathExtension().lastPathComponent) }
            .sorted { $0.analyzedAt > $1.analyzedAt }
    }

    private func load(_ episodeUuid: String) -> EpisodeAdAnalysis? {
        guard let data = try? Data(contentsOf: fileURL(for: episodeUuid)) else { return nil }

        guard let analysis = try? JSONDecoder().decode(EpisodeAdAnalysis.self, from: data), analysis.version == EpisodeAdAnalysis.currentVersion else {
            FileLog.shared.addMessage("AdSpanStore: discarding unreadable analysis for \(episodeUuid)")
            return nil
        }

        return analysis
    }

    private func fileURL(for episodeUuid: String) -> URL {
        directory.appendingPathComponent(episodeUuid).appendingPathExtension("json")
    }
}
