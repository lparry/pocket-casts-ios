import PocketCastsDataModel
import PocketCastsUtils
import SwiftUI

/// Where the listener enters their Claude API key and can see what's been found
struct AdSkippingSettingsView: View {
    @ObservedObject private var manager = AdSkippingManager.shared

    @State private var apiKeyDraft = ""
    @State private var analyses: [EpisodeAdAnalysis] = []

    var body: some View {
        List {
            apiKeySection
            nowPlayingSection
            analysesSection
        }
        .miniPlayerSafeAreaInset()
        .onAppear(perform: reloadAnalyses)
        .onChange(of: manager.analysesVersion) { _, _ in
            reloadAnalyses()
        }
    }

    // MARK: - API Key

    private var apiKeySection: some View {
        Section {
            if manager.apiKey == nil {
                SecureField(L10n.adSkippingApiKeyPlaceholder, text: $apiKeyDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button(L10n.adSkippingApiKeySave) {
                    manager.apiKey = apiKeyDraft
                    apiKeyDraft = ""
                }
                .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                Text(L10n.adSkippingApiKeySaved)
                Button(L10n.adSkippingApiKeyRemove, role: .destructive) {
                    manager.apiKey = nil
                }
            }
        } header: {
            Text(L10n.adSkippingApiKeyHeader)
        } footer: {
            Text(L10n.adSkippingApiKeyFooter)
        }
    }

    // MARK: - Now Playing

    @ViewBuilder
    private var nowPlayingSection: some View {
        if let episode = PlaybackManager.shared.currentEpisode as? Episode {
            Section {
                Text(episode.title ?? "")
                if let status = manager.statuses[episode.uuid] {
                    Text(status.description)
                        .foregroundStyle(.secondary)
                }
                Button(L10n.adSkippingAnalyze) {
                    manager.enqueue(episode.uuid, force: true)
                }
                .disabled(!episode.downloaded(pathFinder: DownloadManager.shared))
            } header: {
                Text(L10n.adSkippingNowPlaying)
            }
        }
    }

    // MARK: - Analyses

    private var analysesSection: some View {
        Section {
            if analyses.isEmpty {
                Text(L10n.adSkippingNoAnalyses)
                    .foregroundStyle(.secondary)
            }
            ForEach(analyses, id: \.episodeUuid) { analysis in
                DisclosureGroup {
                    ForEach(analysis.spans, id: \.self) { span in
                        VStack(alignment: .leading) {
                            Text(L10n.adSkippingSpanRange(format(span.start), format(span.end)))
                                .monospacedDigit()
                            Text([span.kind.rawValue, span.sponsor].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } label: {
                    VStack(alignment: .leading) {
                        Text(title(for: analysis))
                        Text(summary(for: analysis))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    Button(L10n.adSkippingForget, role: .destructive) {
                        manager.removeAnalysis(for: analysis.episodeUuid)
                    }
                }
            }
        } header: {
            Text(L10n.adSkippingAnalysesHeader)
        }
    }

    private func reloadAnalyses() {
        analyses = manager.store.allAnalyses()
    }

    private func title(for analysis: EpisodeAdAnalysis) -> String {
        DataManager.shared.findEpisode(uuid: analysis.episodeUuid)?.title ?? analysis.episodeUuid
    }

    private func summary(for analysis: EpisodeAdAnalysis) -> String {
        let adTime = analysis.spans.reduce(0) { $0 + $1.duration }
        if let status = manager.statuses[analysis.episodeUuid], status != .finished(adCount: analysis.spans.count) {
            return status.description
        }
        return L10n.adSkippingSummary(analysis.spans.count.localized(), format(adTime))
    }

    private func format(_ time: TimeInterval) -> String {
        TimeFormatter.shared.playTimeFormat(time: time)
    }
}

extension AdSkippingManager.Status: CustomStringConvertible {
    var description: String {
        switch self {
        case .queued:
            L10n.adSkippingStatusQueued
        case .transcribing:
            L10n.adSkippingStatusTranscribing
        case .classifying:
            L10n.adSkippingStatusClassifying
        case .finished(let adCount):
            L10n.adSkippingStatusFinished(adCount.localized())
        case .failed(let message):
            L10n.adSkippingStatusFailed(message)
        }
    }
}
