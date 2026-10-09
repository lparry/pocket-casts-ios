import Foundation

struct AdClassificationContext {
    let podcastTitle: String?
    let episodeTitle: String?
    let duration: TimeInterval
}

/// Finds the ads in a timestamped transcript.
///
/// `FoundationModelsAdClassifier` runs on device and is the default. `OpenRouterAdClassifier`
/// is used instead when the listener has saved an OpenRouter key.
protocol AdClassifier {
    /// Stored with each analysis so results from different classifiers can be told apart
    var identifier: String { get }

    func adSpans(in transcript: [TranscriptSegment], context: AdClassificationContext) async throws -> [AdSpan]
}

extension AdClassifier {
    /// Drops short spans, clamps them to the episode, and merges any that overlap
    func cleanedUp(_ spans: [AdSpan], duration: TimeInterval, minimumDuration: TimeInterval = 3) -> [AdSpan] {
        let upperBound = duration > 0 ? duration : .greatestFiniteMagnitude
        let clamped = spans
            .map { AdSpan(start: max(0, $0.start), end: min($0.end, upperBound), kind: $0.kind, sponsor: $0.sponsor?.isEmpty == false ? $0.sponsor : nil) }
            .filter { $0.duration >= minimumDuration }
            .sorted { $0.start < $1.start }

        var merged: [AdSpan] = []
        for span in clamped {
            if let last = merged.last, span.start <= last.end {
                merged[merged.count - 1] = AdSpan(start: last.start, end: max(last.end, span.end), kind: last.kind, sponsor: last.sponsor ?? span.sponsor)
            } else {
                merged.append(span)
            }
        }
        return merged
    }
}

/// The instructions and transcript formatting shared by every classifier
enum AdClassifierPrompt {
    static let instructions = """
    You find the ads in podcast transcripts so the listener's player can skip them.

    Each transcript line is `[start-end] text`, with times in seconds in the listener's own audio file. The transcript \
    was made on device by speech recognition, so expect misheard words, especially brand names.

    Return every ad as a span:
    - host_read: a sponsor read by a host, including lead-ins like "this episode is brought to you by" and the promo code.
    - inserted: a produced or dynamically inserted ad, often in a different voice from the hosts.
    - cross_promo: a trailer or promo for another show.
    - self_promo: the show asking for support, reviews, Patreon, memberships or merch.

    Start each span at the first line of the ad and end it at the end of the last ad line, before the show resumes. Take \
    start and end times from the line boundaries. Give back-to-back ads for different sponsors their own spans. Don't \
    include the show's own content, its intro or outro, or a host mentioning a brand in conversation. `sponsor` is the \
    advertised brand or show, or an empty string if it's unclear. If there are no ads, return an empty list.
    """

    static func line(for segment: TranscriptSegment) -> String {
        String(format: "[%.1f-%.1f] %@", segment.start, segment.end, segment.text)
    }

    static func prompt(transcript: [TranscriptSegment], context: AdClassificationContext) -> String {
        var details: [String] = []
        if let podcastTitle = context.podcastTitle, !podcastTitle.isEmpty {
            details.append("Podcast: \(podcastTitle)")
        }
        if let episodeTitle = context.episodeTitle, !episodeTitle.isEmpty {
            details.append("Episode: \(episodeTitle)")
        }
        if context.duration > 0 {
            details.append("Duration: \(Int(context.duration)) seconds")
        }

        return (details + ["", "<transcript>"] + transcript.map(line(for:)) + ["</transcript>"]).joined(separator: "\n")
    }
}
