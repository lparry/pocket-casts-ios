import PocketCastsDataModel
import PocketCastsUtils
import SwiftUI
import UIKit

/// Every downloaded episode with what Ad Zapping found in it, reached from the Profile tab
struct AdScanningView: View {
    @ObservedObject private var manager = AdSkippingManager.shared

    @State private var episodes: [BaseEpisode] = []

    @ScaledMetric private var thumbnailSize: CGFloat = 44

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
                    manager.scanMissing()
                }
            }

            ForEach(episodes, id: \.uuid) { episode in
                row(for: episode)
            }
        } header: {
            Text(L10n.adSkippingAnalysesHeader)
        }
    }

    /// The row only says how the scan went. Which model found the ads, how long it took, the Scan button and the ads
    /// themselves are behind the chevron.
    private func row(for episode: BaseEpisode) -> some View {
        let analysis = manager.currentAnalysis(for: episode)

        return DisclosureGroup {
            AdZappingDetails(episode: episode)
        } label: {
            rowLabel(for: episode, analysis: analysis)
        }
        .swipeActions {
            if analysis != nil {
                forgetButton(for: episode)
            }
        }
    }

    private func rowLabel(for episode: BaseEpisode, analysis: EpisodeAdAnalysis?) -> some View {
        HStack {
            EpisodeImage(episode: episode)
                .aspectRatio(contentMode: .fill)
                .frame(width: thumbnailSize, height: thumbnailSize)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .accessibilityHidden(true)

            VStack(alignment: .leading) {
                Text(episode.title ?? "")
                Text(AdZappingDetails.status(for: episode, analysis: analysis, manager: manager))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func forgetButton(for episode: BaseEpisode) -> some View {
        Button(L10n.adSkippingForget, role: .destructive) {
            manager.removeAnalysis(for: episode.uuid)
        }
    }

    private func reloadEpisodes() {
        episodes = manager.downloadedEpisodes()
    }
}
