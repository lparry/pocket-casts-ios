import Foundation

struct AdClassificationContext {
    let podcastTitle: String?
    let episodeTitle: String?
    let duration: TimeInterval
}

/// Finds the ads in a timestamped transcript.
///
/// `OpenRouterAdClassifier` finds the ads, with the listener's own key. `FoundationModelsAdClassifier` runs on
/// device, and is only a backup for when an OpenRouter request fails.
protocol AdClassifier {
    /// Stored with each analysis so results from different classifiers can be told apart
    var identifier: String { get }

    func adSpans(in transcript: [TranscriptSegment], context: AdClassificationContext) async throws -> [AdSpan]

    /// For each request, which word in its `words` is the ad's first (for `.start`) or last (for `.end`), or nil if it
    /// isn't in them. An episode's edges all come at once, so a remote classifier can answer them in one call.
    func boundaryWordIndices(for requests: [AdBoundaryRequest]) async throws -> [Int?]

    /// Whether it runs on this device, so it takes turns with transcribing
    var runsOnDevice: Bool { get }
}

extension AdClassifier {
    var runsOnDevice: Bool {
        false
    }
}

enum AdBoundaryEdge {
    case start
    case end
}

/// The words around one edge of an ad, for a classifier to pick exactly where the ad starts or ends
struct AdBoundaryRequest {
    let edge: AdBoundaryEdge
    let ad: AdSpan
    let words: [TimedWord]
    let context: AdClassificationContext
}

extension AdClassifier {
    /// Drops spans too short or too long to be ads of their kind, clamps them to the episode, and merges any that overlap.
    /// Short spans go first, so they can't be joined into a longer skip.
    ///
    /// Network branding is only judged once the episode's `words` are given, after its edges have been placed: the
    /// transcript line for a one word ident can be shorter than the ident and its sting.
    func cleanedUp(_ spans: [AdSpan], duration: TimeInterval, words: [TimedWord]? = nil) -> [AdSpan] {
        let upperBound = duration > 0 ? duration : .greatestFiniteMagnitude
        var clamped = spans
            .map { AdSpan(start: max(0, $0.start), end: min($0.end, upperBound), kind: $0.kind, sponsor: $0.sponsor?.isEmpty == false ? $0.sponsor : nil) }
        if let words {
            clamped = NetworkBranding.placed(clamped, words: words, duration: duration)
        }
        clamped = clamped
            .filter { span in
                let isTooShort = span.duration < span.minimumDuration && (words != nil || span.kind != .networkBranding)
                let isTooLong = span.maximumDuration.map { span.duration > $0 } ?? false
                return !isTooShort && !isTooLong
            }
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

/// Short publisher idents, like "Pushkin." or "This is the Guardian.", only come before the show starts or after it ends,
/// so they're only kept there. Anywhere else a short span is far more likely to be the show itself.
enum NetworkBranding {
    /// How many words of the show can come between an ident and the start or end of the episode. Words in other ads
    /// don't count, so an ident after the pre-roll ads is kept.
    static let maximumShowWordsOutside = 3

    /// Drops network branding that isn't at the start or end of the episode, and stretches an ident with no words
    /// before it back to the start, or with no words after it on to the end, over the sting or music around it
    static func placed(_ spans: [AdSpan], words: [TimedWord], duration: TimeInterval) -> [AdSpan] {
        spans.enumerated().compactMap { index, span in
            guard span.kind == .networkBranding else { return span }

            let others = spans.enumerated().filter { $0.offset != index }.map(\.element)
            let showWords = words.filter { word in
                let middle = (word.start + word.end) / 2
                return !span.contains(middle) && !others.contains { $0.contains(middle) }
            }
            let isAtStart = showWords.filter { $0.end <= span.start }.count <= maximumShowWordsOutside
            let isAtEnd = showWords.filter { $0.start >= span.end }.count <= maximumShowWordsOutside
            guard isAtStart || isAtEnd else { return nil }

            let start = words.contains { $0.end <= span.start } ? span.start : 0
            let end = words.contains { $0.start >= span.end } || duration <= 0 ? span.end : max(span.end, duration)
            return AdSpan(start: start, end: end, kind: span.kind, sponsor: span.sponsor)
        }
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
    - network_branding: a brief ident for the podcast's publisher or network before the show starts or after it ends, \
    often a single line and a sound effect, like "Pushkin." or "This is the Guardian." The show's own title, theme \
    or intro is not network branding, and neither is a host mentioning the network in conversation. It never comes in \
    the middle of the show.

    Start each span at the first line of the ad, including lead-ins like "we'll be right back", "after the break", \
    "a word from our sponsors" or "this episode is brought to you by". End it at the end of the last ad line, including \
    outros like "now back to the show" or "thanks to our sponsor", before the show resumes. Take start and end times \
    from the line boundaries. Give back-to-back ads for different sponsors their own spans, each running right up to \
    the next. Don't include the show's own content, its intro or outro, or a host mentioning a brand in conversation, \
    though a network ident before the intro or after the outro is network_branding. \
    `sponsor` is the advertised brand or show, or an empty string if it's unclear. If there are no ads, return an empty \
    list.
    """

    static let boundaryInstructions = """
    You pin down exactly where an ad in a podcast starts or ends, so the listener's player can skip all of it and none \
    of the show.

    You'll get the words spoken around one edge of an ad, one per line as `index [time] word`, with times in seconds. \
    The transcript was made by speech recognition, so expect misheard words.

    For the start of an ad, give the index of its first word. Lead-ins are part of the ad: "we'll be right back", \
    "after the break", "a word from our sponsors", "this episode is brought to you by", "support for the show comes \
    from". For the end of an ad, give the index of its last word. Outros are part of the ad too: "now back to the \
    show", "thanks to our sponsor", a promo code or web address. Give -1 if the edge isn't in these words.
    """

    static let batchedBoundaryInstructions = boundaryInstructions + """


    You'll get several edges at once, each in its own `<edge>` element with its own word indexes. Answer every edge, by \
    its `id`.
    """

    static func boundaryPrompt(for requests: [AdBoundaryRequest]) -> String {
        requests.enumerated().map { id, request in
            "<edge id=\"\(id)\">\n\(boundaryPrompt(for: request))\n</edge>"
        }.joined(separator: "\n\n")
    }

    static func boundaryPrompt(for request: AdBoundaryRequest) -> String {
        let task = switch request.edge {
        case .start:
            "Which word starts this ad?"
        case .end:
            "Which word ends this ad?"
        }

        var lines = [task, "Ad kind: \(request.ad.kind.rawValue)"]
        if let sponsor = request.ad.sponsor {
            lines.append("Sponsor: \(sponsor)")
        }
        if let podcastTitle = request.context.podcastTitle, !podcastTitle.isEmpty {
            lines.append("Podcast: \(podcastTitle)")
        }
        lines.append("Roughly \(String(format: "%.1f", request.edge == .start ? request.ad.start : request.ad.end)) seconds")
        lines.append("")
        lines.append("<words>")
        lines += request.words.enumerated().map { index, word in
            String(format: "%d [%.2f] %@", index, word.start, word.text)
        }
        lines.append("</words>")

        return lines.joined(separator: "\n")
    }

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
