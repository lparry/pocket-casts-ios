import PocketCastsDataModel
import PocketCastsUtils
import SwiftUI

/// What Ad Zapping found in one downloaded episode: which model found its ads and how long that took, a button to scan
/// it, and each ad with what was said in it. Shown behind an episode's chevron on the Ad Zapping screen, and in the
/// player's Ad Zapping tab.
///
/// Each part is its own view, so in a `List` each becomes a row, and in a `VStack` they stack up.
struct AdZappingDetails: View {
    let episode: BaseEpisode
    /// The player shows how the scan went here, while the Ad Zapping screen shows it beside the episode
    var showsStatus = false

    @ObservedObject private var manager = AdSkippingManager.shared

    /// The words of each ad, read once the details are showing
    @State private var transcripts: TranscriptState = .loading

    private enum TranscriptState {
        case loading
        case loaded([AdSpan: AdTranscriptExcerpt])
        case missing
    }

    var body: some View {
        let analysis = manager.currentAnalysis(for: episode)

        if showsStatus {
            Text(Self.status(for: episode, analysis: analysis, manager: manager))
                .font(.subheadline)
        }

        if let analysis {
            Text(Self.detailsDescription(analysis))
                .font(.caption)
                .foregroundStyle(.secondary)
                // A rescan changes the ads, so their words are read again
                .task(id: analysis.analyzedAt) {
                    await loadTranscripts(for: analysis)
                }
        }

        if manager.isScanning(episode), !Self.isInProgress(episode, manager: manager) {
            Button(analysis == nil ? L10n.adSkippingScan : L10n.adSkippingRescan) {
                manager.enqueue(episode.uuid, force: true, first: true, requested: true)
            }
            .buttonStyle(.borderless)
        }

        if let analysis {
            ForEach(analysis.spans, id: \.self) { span in
                adRow(span)
            }
        }
    }

    private func adRow(_ span: AdSpan) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading) {
                    Text(L10n.adSkippingSpanRange(Self.format(span.start), Self.format(span.end)))
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

            adTranscript(span)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func adTranscript(_ span: AdSpan) -> some View {
        switch transcripts {
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
        case .loading:
            ProgressView()
                .controlSize(.small)
        }
    }

    private func loadTranscripts(for analysis: EpisodeAdAnalysis) async {
        transcripts = .loading
        let excerpts = await manager.adTranscripts(for: episode, spans: analysis.spans)
        guard !Task.isCancelled else { return }
        transcripts = excerpts.map(TranscriptState.loaded) ?? .missing
    }

    // MARK: - Descriptions

    /// How the episode's scan went, like how many ads were found, or how far through transcribing it is
    @MainActor
    static func status(for episode: BaseEpisode, analysis: EpisodeAdAnalysis?, manager: AdSkippingManager) -> String {
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
            return L10n.adSkippingSummary(analysis.spans.count.localized(), format(adTime))
        case .some(let status):
            return status.description
        }
    }

    @MainActor
    static func isInProgress(_ episode: BaseEpisode, manager: AdSkippingManager) -> Bool {
        switch manager.statuses[episode.uuid] {
        case .queued, .transcribing, .classifying:
            true
        default:
            false
        }
    }

    private static func detailsDescription(_ analysis: EpisodeAdAnalysis) -> String {
        let foundBy = L10n.adScanningFoundBy(AdSkippingSettingsView.modelName(forClassifier: analysis.classifier))
        guard let timings = analysis.timings else { return foundBy }
        return foundBy + "\n" + timingsDescription(timings)
    }

    private static func timingsDescription(_ timings: AdScanTimings) -> String {
        let transcription = if let transcription = timings.transcription, let speed = timings.transcriptionSpeed {
            L10n.adScanningTimingsTranscribed(format(timings.audioDuration ?? 0), formatTimeTaken(transcription), speed.localized())
        } else {
            L10n.adScanningTimingsReused
        }
        let steps = L10n.adScanningTimingsSteps(formatTimeTaken(timings.firstPass), formatTimeTaken(timings.edgePass), formatTimeTaken(timings.audioSnapping))

        let snapping: String? = if timings.audioUnreadable == true {
            L10n.adScanningTimingsAudioUnreadable
        } else if let snappedEdges = timings.snappedEdges, let edgeCount = timings.edgeCount, edgeCount > 0 {
            L10n.adScanningTimingsSnappedEdges(snappedEdges.localized(), edgeCount.localized())
        } else {
            nil
        }

        return ([transcription, steps] + [snapping].compactMap { $0 }).joined(separator: "\n")
    }

    /// How long a step took. Some take well under a second, which would round to 0:00 as a play time, so those are
    /// shown in seconds, like 0.4s.
    static func formatTimeTaken(_ time: TimeInterval) -> String {
        guard time < 60 else { return TimeFormatter.shared.playTimeFormat(time: time) }
        return Measurement(value: time, unit: UnitDuration.seconds)
            .formatted(.measurement(width: .narrow, numberFormatStyle: .number.precision(.fractionLength(time < 10 ? 1 : 0))))
    }

    private static func format(_ time: TimeInterval) -> String {
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
