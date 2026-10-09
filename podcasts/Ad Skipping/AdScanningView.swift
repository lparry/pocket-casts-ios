import PocketCastsDataModel
import PocketCastsUtils
import SwiftUI
import UIKit

/// Every downloaded episode with its ad scan state, reached from the Profile tab
struct AdScanningView: View {
    @ObservedObject private var manager = AdSkippingManager.shared

    @State private var episodes: [BaseEpisode] = []

    static func makeViewController() -> UIViewController {
        let hostingController = UIHostingController(rootView: AdScanningView().setupDefaultEnvironment())
        hostingController.title = L10n.adScanningTitle
        return hostingController
    }

    var body: some View {
        List {
            episodesSection
        }
        .miniPlayerSafeAreaInset()
        .onAppear {
            reloadEpisodes()
            manager.scanMissing()
        }
        .onChange(of: manager.analysesVersion) { _, _ in
            reloadEpisodes()
        }
    }

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

            if manager.isScanning(episode), !isInProgress(episode) {
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

    private func isInProgress(_ episode: BaseEpisode) -> Bool {
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
        guard manager.isScanning(episode) else { return L10n.adSkippingStatusOffForPodcast }

        switch manager.statuses[episode.uuid] {
        case .some(.finished), .none:
            guard let analysis else { return L10n.adSkippingStatusNotScanned }

            let adTime = analysis.spans.reduce(0) { $0 + $1.duration }
            if analysis.isSuspect {
                return L10n.adSkippingStatusSuspect(analysis.spans.count.localized(), format(adTime))
            }
            return L10n.adSkippingSummary(analysis.spans.count.localized(), format(adTime), AdSkippingSettingsView.displayName(forClassifier: analysis.classifier))
        case .some(let status):
            return status.description
        }
    }

    private func format(_ time: TimeInterval) -> String {
        TimeFormatter.shared.playTimeFormat(time: time)
    }
}
