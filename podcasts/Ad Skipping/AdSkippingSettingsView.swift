import PocketCastsDataModel
import PocketCastsUtils
import SwiftUI

/// Where the listener sees how ads are found, enters an OpenRouter key, and sees the scan state of every download
struct AdSkippingSettingsView: View {
    @ObservedObject private var manager = AdSkippingManager.shared

    @State private var apiKeyDraft = ""
    @State private var modelDraft = ""
    @State private var episodes: [BaseEpisode] = []

    var body: some View {
        List {
            classifierSection
            kindsSection
            openRouterSection
            episodesSection
        }
        .miniPlayerSafeAreaInset()
        .onAppear {
            modelDraft = manager.openRouterModel
            reloadEpisodes()
            manager.scanMissing()
        }
        .onDisappear {
            manager.openRouterModel = modelDraft
        }
        .onChange(of: manager.analysesVersion) { _, _ in
            reloadEpisodes()
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

    // MARK: - Kinds

    private var kindsSection: some View {
        Section {
            ForEach(AdSpan.Kind.allCases, id: \.self) { kind in
                Toggle(kind.displayName, isOn: Binding(
                    get: { manager.skippedKinds.contains(kind) },
                    set: { manager.setSkipping(kind, $0) }
                ))
            }
        } header: {
            Text(L10n.adSkippingKindsHeader)
        } footer: {
            Text(L10n.adSkippingKindsFooter)
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

    // MARK: - Episodes

    private var episodesSection: some View {
        Section {
            if episodes.isEmpty {
                Text(L10n.adSkippingNoDownloads)
                    .foregroundStyle(.secondary)
            } else {
                Button(L10n.adSkippingScanAll) {
                    manager.scanMissing(includingFailed: true)
                }
            }

            ForEach(episodes, id: \.uuid) { episode in
                row(for: episode)
            }
        } header: {
            Text(L10n.adSkippingAnalysesHeader)
        }
    }

    @ViewBuilder
    private func row(for episode: BaseEpisode) -> some View {
        let analysis = manager.currentAnalysis(for: episode)

        if let analysis, !analysis.spans.isEmpty {
            DisclosureGroup {
                ForEach(analysis.spans, id: \.self) { span in
                    VStack(alignment: .leading) {
                        Text(L10n.adSkippingSpanRange(format(span.start), format(span.end)))
                            .monospacedDigit()
                        Text([span.kind.displayName, span.sponsor].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } label: {
                rowLabel(for: episode, analysis: analysis)
            }
            .swipeActions {
                forgetButton(for: episode)
            }
        } else {
            rowLabel(for: episode, analysis: analysis)
                .swipeActions {
                    if analysis != nil {
                        forgetButton(for: episode)
                    }
                }
        }
    }

    private func rowLabel(for episode: BaseEpisode, analysis: EpisodeAdAnalysis?) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(episode.title ?? "")
                Text(state(for: episode, analysis: analysis))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !isScanning(episode) {
                Button(analysis == nil ? L10n.adSkippingScan : L10n.adSkippingRescan) {
                    manager.enqueue(episode.uuid, force: true, first: true)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func forgetButton(for episode: BaseEpisode) -> some View {
        Button(L10n.adSkippingForget, role: .destructive) {
            manager.removeAnalysis(for: episode.uuid)
        }
    }

    private func isScanning(_ episode: BaseEpisode) -> Bool {
        switch manager.statuses[episode.uuid] {
        case .queued, .transcribing, .classifying:
            true
        default:
            false
        }
    }

    private func reloadEpisodes() {
        episodes = manager.downloadedEpisodes()
    }

    private func state(for episode: BaseEpisode, analysis: EpisodeAdAnalysis?) -> String {
        switch manager.statuses[episode.uuid] {
        case .some(.finished), .none:
            guard let analysis else { return L10n.adSkippingStatusNotScanned }

            let adTime = analysis.spans.reduce(0) { $0 + $1.duration }
            return L10n.adSkippingSummary(analysis.spans.count.localized(), format(adTime), Self.displayName(forClassifier: analysis.classifier))
        case .some(let status):
            return status.description
        }
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

extension AdSpan.Kind {
    var displayName: String {
        switch self {
        case .hostRead:
            L10n.adSkippingKindHostRead
        case .inserted:
            L10n.adSkippingKindInserted
        case .crossPromo:
            L10n.adSkippingKindCrossPromo
        case .selfPromo:
            L10n.adSkippingKindSelfPromo
        }
    }
}
