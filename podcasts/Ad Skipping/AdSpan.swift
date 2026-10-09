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

    func contains(_ time: TimeInterval) -> Bool {
        time >= start && time < end
    }
}

/// One timestamped line of an on-device transcript
struct TranscriptSegment: Codable, Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

/// The ads found in one downloaded episode, persisted so each download is only analysed once
struct EpisodeAdAnalysis: Codable, Equatable {
    static let currentVersion = 1

    let version: Int
    let episodeUuid: String
    let analyzedAt: Date
    /// Which `AdClassifier` produced the spans
    let classifier: String
    /// The size of the download that was transcribed, so a re-download with different ads isn't skipped with stale spans
    let audioFileSize: UInt64?
    let transcriptSegmentCount: Int
    let spans: [AdSpan]
}

enum AdSkippingError: LocalizedError {
    case notDownloaded
    case noClassifier
    case transcriptionUnavailable
    case unsupportedLocale(Locale)
    case emptyTranscript
    case classifierFailed(String)

    var errorDescription: String? {
        switch self {
        case .notDownloaded:
            "The episode isn't downloaded"
        case .noClassifier:
            "Add an OpenRouter key, or turn on Apple Intelligence to find ads on device"
        case .transcriptionUnavailable:
            "On-device transcription needs iOS 26 or later on a supported device"
        case .unsupportedLocale(let locale):
            "On-device transcription doesn't support \(locale.identifier)"
        case .emptyTranscript:
            "The transcript came back empty"
        case .classifierFailed(let message):
            message
        }
    }
}
