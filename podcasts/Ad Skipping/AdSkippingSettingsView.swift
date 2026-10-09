import PocketCastsDataModel
import PocketCastsUtils
import SwiftUI

/// Where the listener sees how ads are found, enters an OpenRouter key, and sees what's been found
struct AdSkippingSettingsView: View {
    @ObservedObject private var manager = AdSkippingManager.shared

    @State private var apiKeyDraft = ""
    @State private var modelDraft = ""
    @State private var analyses: [EpisodeAdAnalysis] = []

    var body: some View {
        List {
            classifierSection
            openRouterSection
            nowPlayingSection
            analysesSection
        }
        .miniPlayerSafeAreaInset()
        .onAppear {
            modelDraft = manager.openRouterModel
            reloadAnalyses()
        }
        .onDisappear {
            manager.openRouterModel = modelDraft
        }
        .onChange(of: manager.analysesVersion) { _, _ in
            reloadAnalyses()
        }
    }

    // MARK: - Classifier

    private var classifierSection: some View {
        Section {
            if let active = manager.classifiers.first {
                Text(L10n.adSkippingClassifierActive(Self.displayName(forClassifier: active.identifier)))
            } else {
                Text(AdSkippingError.noClassifier.localizedDescription)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text(L10n.adSkippingClassifierFooter)
        }
    }

    // MARK: - OpenRouter

    private var openRouterSection: some View {
        Section {
            if manager.openRouterApiKey == nil {
                SecureField(L10n.adSkippingApiKeyPlaceholder, text: $apiKeyDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button(L10n.adSkippingApiKeySave) {
                    manager.openRouterApiKey = apiKeyDraft
                    apiKeyDraft = ""
                }
                .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                Text(L10n.adSkippingApiKeySaved)
                Button(L10n.adSkippingApiKeyRemove, role: .destructive) {
                    manager.openRouterApiKey = nil
                }
            }

            LabeledContent(L10n.adSkippingModel) {
                TextField(OpenRouterAdClassifier.defaultModel, text: $modelDraft)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit {
                        manager.openRouterModel = modelDraft
                        modelDraft = manager.openRouterModel
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
        if let status = manager.statuses[analysis.episodeUuid], status != .finished(adCount: analysis.spans.count, classifier: analysis.classifier) {
            return status.description
        }
        return L10n.adSkippingSummary(analysis.spans.count.localized(), format(adTime), Self.displayName(forClassifier: analysis.classifier))
    }

    static func displayName(forClassifier identifier: String) -> String {
        if identifier.hasPrefix(OpenRouterAdClassifier.identifierPrefix) {
            return L10n.adSkippingClassifierOpenrouter(String(identifier.dropFirst(OpenRouterAdClassifier.identifierPrefix.count)))
        }
        return L10n.adSkippingClassifierOnDevice
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
        case .finished(let adCount, let classifier):
            L10n.adSkippingStatusFinished(adCount.localized(), AdSkippingSettingsView.displayName(forClassifier: classifier))
        case .failed(let message):
            L10n.adSkippingStatusFailed(message)
        }
    }
}
