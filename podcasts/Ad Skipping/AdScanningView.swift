import PocketCastsDataModel
import PocketCastsUtils
import SwiftUI
import UIKit

/// Every downloaded episode with its ad scan state, reached from the Profile tab
struct AdScanningView: View {
    @ObservedObject private var manager = AdSkippingManager.shared

    @State private var episodes: [BaseEpisode] = []
    /// Episodes whose ads are showing
    @State private var expanded: Set<String> = []
    /// The words of each episode's ads, read when it's first expanded
    @State private var transcripts: [String: TranscriptState] = [:]

    @ScaledMetric private var thumbnailSize: CGFloat = 44

    private enum TranscriptState {
        case loading
        case loaded([AdSpan: AdTranscriptExcerpt])
        case missing
    }

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
            // A rescan changes the ads, so read their words again
            transcripts = [:]
            for episode in episodes where expanded.contains(episode.uuid) {
                if let analysis = manager.currentAnalysis(for: episode) {
                    loadTranscripts(for: episode, analysis: analysis)
                }
            }
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

    @ViewBuilder
    private func row(for episode: BaseEpisode) -> some View {
        let analysis = manager.currentAnalysis(for: episode)

        if let analysis, !analysis.spans.isEmpty || analysis.timings != nil {
            DisclosureGroup(isExpanded: isExpanded(episode, analysis: analysis)) {
                if let timings = analysis.timings {
                    Text(timingsDescription(timings))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(analysis.spans, id: \.self) { span in
                    adRow(span, in: episode)
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

    private func adRow(_ span: AdSpan, in episode: BaseEpisode) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading) {
                    Text(L10n.adSkippingSpanRange(format(span.start), format(span.end)))
                        .monospacedDigit()
                    Text([span.kind.displayName, span.sponsor].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    manager.play(span, in: episode)
                } label: {
                    Image(systemName: "play.circle")
                        .imageScale(.large)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L10n.adScanningPlayAd)
            }

            adTranscript(span, in: episode)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func adTranscript(_ span: AdSpan, in episode: BaseEpisode) -> some View {
        switch transcripts[episode.uuid] {
        case .loaded(let excerpts):
            if let excerpt = excerpts[span], !excerpt.ad.isEmpty {
                AdTranscriptText(excerpt: excerpt)
            } else {
                Text(L10n.adScanningTranscriptEmpty)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .missing:
            Text(L10n.adScanningTranscriptMissing)
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .loading, .none:
            ProgressView()
                .controlSize(.small)
        }
    }

    private func isExpanded(_ episode: BaseEpisode, analysis: EpisodeAdAnalysis) -> Binding<Bool> {
        Binding {
            expanded.contains(episode.uuid)
        } set: { isExpanded in
            if isExpanded {
                expanded.insert(episode.uuid)
                loadTranscripts(for: episode, analysis: analysis)
            } else {
                expanded.remove(episode.uuid)
            }
        }
    }

    private func loadTranscripts(for episode: BaseEpisode, analysis: EpisodeAdAnalysis) {
        guard transcripts[episode.uuid] == nil else { return }

        transcripts[episode.uuid] = .loading
        Task {
            let excerpts = await manager.adTranscripts(for: episode, spans: analysis.spans)
            // Drop the words if the episode was rescanned while they were being read
            guard manager.currentAnalysis(for: episode)?.analyzedAt == analysis.analyzedAt else { return }
            transcripts[episode.uuid] = excerpts.map(TranscriptState.loaded) ?? .missing
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
                Text(state(for: episode, analysis: analysis))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if manager.isScanning(episode), !isInProgress(episode) {
                Button(analysis == nil ? L10n.adSkippingScan : L10n.adSkippingRescan) {
                    manager.enqueue(episode.uuid, force: true, first: true, requested: true)
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
            guard let analysis else {
                if let failure = manager.scanFailure(for: episode) {
                    return L10n.adSkippingStatusFailed(failure.message)
                }
                return L10n.adSkippingStatusNotScanned
            }

            let adTime = analysis.spans.reduce(0) { $0 + $1.duration }
            if analysis.isSuspect {
                return L10n.adSkippingStatusSuspect(analysis.spans.count.localized(), format(adTime))
            }
            return L10n.adSkippingSummary(analysis.spans.count.localized(), format(adTime), AdSkippingSettingsView.displayName(forClassifier: analysis.classifier))
        case .some(let status):
            return status.description
        }
    }

    private func timingsDescription(_ timings: AdScanTimings) -> String {
        let transcription = if let transcription = timings.transcription, let speed = timings.transcriptionSpeed {
            L10n.adScanningTimingsTranscribed(format(timings.audioDuration ?? 0), format(transcription), speed.localized())
        } else {
            L10n.adScanningTimingsReused
        }
        return transcription + "\n" + L10n.adScanningTimingsSteps(format(timings.firstPass), format(timings.edgePass), format(timings.audioSnapping))
    }

    private func format(_ time: TimeInterval) -> String {
        TimeFormatter.shared.playTimeFormat(time: time)
    }
}

/// An ad's words, with what was said either side of it dimmed, so it's clear where its edges were placed
private struct AdTranscriptText: View {
    let excerpt: AdTranscriptExcerpt

    @State private var isExpanded = false

    /// Longer ads start out cut down to a few lines
    private static let collapsedLineLimit = 4
    private static let collapsibleLength = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .font(.footnote)
                .lineLimit(isExpanded ? nil : Self.collapsedLineLimit)

            if excerpt.ad.count > Self.collapsibleLength {
                Button(isExpanded ? L10n.adScanningShowLess : L10n.adScanningShowMore) {
                    isExpanded.toggle()
                }
                .font(.footnote)
                .buttonStyle(.borderless)
            }
        }
    }

    private var text: AttributedString {
        var before = AttributedString(excerpt.before.isEmpty ? "" : "…" + excerpt.before + " ")
        before.foregroundColor = .secondary
        var after = AttributedString(excerpt.after.isEmpty ? "" : " " + excerpt.after + "…")
        after.foregroundColor = .secondary
        return before + AttributedString(excerpt.ad) + after
    }
}
