import Foundation

/// A stretch of an episode that's an ad, in the listener's own playback timeline.
///
/// Times come from transcribing the downloaded file, so dynamically inserted ads land
/// wherever they are in this particular download.
struct AdSpan: Codable, Equatable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        /// A sponsor read by the host
        case hostRead = "host_read"
        /// A produced or dynamically inserted ad
        case inserted
        /// A promo for another show
        case crossPromo = "cross_promo"
        /// The show asking for support, reviews, Patreon or merch
        case selfPromo = "self_promo"
    }

    let start: TimeInterval
    let end: TimeInterval
    let kind: Kind
    /// The advertised brand or show, when the classifier could tell
    let sponsor: String?

    var duration: TimeInterval {
        end - start
    }

    /// Anything shorter is almost certainly the hosts talking, not an ad. Real inserted ads on the listener's
    /// phone were as short as 14.3s, and a broadcaster's own promos as short as 5.2s.
    var minimumDuration: TimeInterval {
        switch kind {
        case .hostRead, .inserted:
            12
        case .crossPromo:
            8
        case .selfPromo:
            5
        }
    }

    func contains(_ time: TimeInterval) -> Bool {
        time >= start && time < end
    }
}

/// One or more ads in a row, skipped together
struct AdSkip: Equatable {
    let spans: [AdSpan]

    var start: TimeInterval {
        spans.first?.start ?? 0
    }

    var end: TimeInterval {
        spans.last?.end ?? 0
    }
}

/// One word of an on-device transcript, with when it was spoken
struct TimedWord: Codable, Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

/// One timestamped line of an on-device transcript
struct TranscriptSegment: Codable, Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    /// The words in the line, used to find exactly where an ad starts and ends
    var words: [TimedWord] = []
}

extension TranscriptSegment {
    /// Groups words into short lines, breaking at the end of a sentence, at a pause, or before a line gets too long.
    /// Short lines let the classifier place an ad's edges close to where they really are.
    static func lines(from words: [TimedWord], maxDuration: TimeInterval = 5, pause: TimeInterval = 0.5) -> [TranscriptSegment] {
        var lines: [TranscriptSegment] = []
        var current: [TimedWord] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            lines.append(TranscriptSegment(start: first.start, end: last.end, text: current.map(\.text).joined(separator: " "), words: current))
            current = []
        }

        for word in words {
            if let first = current.first, let previous = current.last,
               word.start - previous.end >= pause || word.end - first.start > maxDuration {
                flush()
            }

            current.append(word)

            if let lastCharacter = word.text.last, ".?!".contains(lastCharacter) {
                flush()
            }
        }
        flush()

        return lines
    }
}

/// The ads found in one downloaded episode, persisted so each download is only analysed once
struct EpisodeAdAnalysis: Codable, Equatable {
    /// Bump to rescan every episode when the way ads are found improves
    static let currentVersion = 3

    let version: Int
    let episodeUuid: String
    let analyzedAt: Date
    /// Which `AdClassifier` produced the spans
    let classifier: String
    /// The size of the download that was transcribed, so a re-download with different ads isn't skipped with stale spans
    let audioFileSize: UInt64?
    let transcriptSegmentCount: Int
    let spans: [AdSpan]
    /// Set when the spans look implausible, so they're shown but never skipped
    var isSuspect = false
    /// How long each step of the scan took
    var timings: AdScanTimings?
}

/// How long each step of a scan took, to see where the time goes
struct AdScanTimings: Codable, Equatable {
    /// How much audio there was
    var audioDuration: TimeInterval?
    /// Nil when a saved transcript was reused
    var transcription: TimeInterval?
    var firstPass: TimeInterval = 0
    var edgePass: TimeInterval = 0
    var audioSnapping: TimeInterval = 0

    /// How many seconds of audio were transcribed each second
    var transcriptionSpeed: Double? {
        guard let audioDuration, let transcription, transcription > 0 else { return nil }
        return audioDuration / transcription
    }
    var logDescription: String {
        let transcribed = if let transcription {
            String(format: "transcribed %.0fs of audio in %.1fs (%.1fx)", audioDuration ?? 0, transcription, transcriptionSpeed ?? 0)
        } else {
            "reused the saved transcript"
        }
        return transcribed + String(format: ", first pass %.1fs, edge pass %.1fs, audio snapping %.1fs", firstPass, edgePass, audioSnapping)
    }
}

extension EpisodeAdAnalysis {
    /// Whether this many ads couldn't be right: more than 40% of the episode, or more than 24 an hour.
    /// A real news episode on the listener's phone had 8 ads, 23% of its length, at about 19 an hour.
    static func looksWrong(_ spans: [AdSpan], duration: TimeInterval) -> Bool {
        guard duration > 0 else { return false }

        let adTime = spans.reduce(0) { $0 + $1.duration }
        let perHour = Double(spans.count) / (duration / 3600)
        return adTime / duration > 0.4 || (spans.count > 6 && perHour > 24)
    }
}

enum AdSkippingError: LocalizedError {
    case notDownloaded
    case noClassifier
    case transcriptionUnavailable
    case unsupportedLocale(Locale)
    case emptyTranscript
    case classifierFailed(String)
    /// The classifier couldn't be reached or turned the request away, so it's worth trying again later
    case classifierUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .notDownloaded:
            "The episode isn't downloaded"
        case .noClassifier:
            "Add an OpenRouter key to find ads"
        case .transcriptionUnavailable:
            "On-device transcription needs iOS 26 or later on a supported device"
        case .unsupportedLocale(let locale):
            "On-device transcription doesn't support \(locale.identifier)"
        case .emptyTranscript:
            "The transcript came back empty"
        case .classifierFailed(let message), .classifierUnavailable(let message):
            message
        }
    }

    /// Whether the error is a network or account problem that will likely clear up, rather than something about the episode
    static func isRetryable(_ error: Error) -> Bool {
        if error is URLError {
            return true
        }
        if case AdSkippingError.classifierUnavailable = error {
            return true
        }
        return false
    }

    /// Whether scanning the same file with the same classifiers would only fail the same way again, so it's not worth
    /// repeating until one of them changes. Unexpected errors, like the speech model failing to download, aren't counted.
    static func isPermanent(_ error: Error) -> Bool {
        guard let error = error as? AdSkippingError else { return false }

        switch error {
        case .classifierFailed, .emptyTranscript, .unsupportedLocale, .transcriptionUnavailable:
            return true
        case .notDownloaded, .noClassifier, .classifierUnavailable:
            return false
        }
    }
}
