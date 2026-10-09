import Foundation
import PocketCastsUtils

struct AdClassificationContext {
    let podcastTitle: String?
    let episodeTitle: String?
    let duration: TimeInterval
}

/// Finds the ads in a timestamped transcript.
///
/// `ClaudeAdClassifier` is the only implementation today; an on-device Foundation Models
/// classifier can slot in behind this later.
protocol AdClassifier {
    /// Stored with each analysis so results from different classifiers can be told apart
    var identifier: String { get }

    func adSpans(in transcript: [TranscriptSegment], context: AdClassificationContext) async throws -> [AdSpan]
}

extension AdClassifier {
    /// Drops empty spans, clamps them to the episode, and merges any that overlap
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

/// Asks the Claude API, with the listener's own API key, to find the ads in a transcript
struct ClaudeAdClassifier: AdClassifier {
    static let model = "claude-opus-5-5"

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let fallbackBeta = "server-side-fallback-2026-07-01"

    let apiKey: String
    var session: URLSession = .shared

    var identifier: String {
        "claude:\(Self.model)"
    }

    func adSpans(in transcript: [TranscriptSegment], context: AdClassificationContext) async throws -> [AdSpan] {
        let body = Self.requestBody(transcript: transcript, context: context)

        let response: Response
        do {
            response = try await send(body, withFallbacks: true)
        } catch ClassifierRequestError.badRequest(let message) {
            // Server-side fallbacks are a beta, so if the request is rejected try once more without them
            FileLog.shared.addMessage("ClaudeAdClassifier: request rejected (\(message)), retrying without fallbacks")
            response = try await send(body, withFallbacks: false)
        }

        switch response.stopReason {
        case "refusal":
            throw AdSkippingError.classifierFailed("Claude declined to classify this episode")
        case "max_tokens":
            throw AdSkippingError.classifierFailed("Claude's response was cut off")
        default:
            break
        }

        guard let text = response.content.last(where: { $0.type == "text" })?.text, let data = text.data(using: .utf8) else {
            throw AdSkippingError.classifierFailed("Claude's response had no text")
        }

        let result = try JSONDecoder().decode(ClassifierOutput.self, from: data)
        let spans = result.ads.map { AdSpan(start: $0.start, end: $0.end, kind: $0.kind, sponsor: $0.sponsor) }
        return cleanedUp(spans, duration: context.duration)
    }

    // MARK: - Request

    private enum ClassifierRequestError: Error {
        case badRequest(String)
    }

    private func send(_ body: [String: Any], withFallbacks: Bool) async throws -> Response {
        var body = body
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if withFallbacks {
            request.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta")
            body["fallbacks"] = "default"
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, urlResponse) = try await session.data(for: request)
        let statusCode = (urlResponse as? HTTPURLResponse)?.statusCode ?? 0

        guard (200..<300).contains(statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error.message ?? "HTTP \(statusCode)"
            if statusCode == 400, withFallbacks {
                throw ClassifierRequestError.badRequest(message)
            }
            throw AdSkippingError.classifierFailed("Claude API error: \(message)")
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Response.self, from: data)
    }

    static func requestBody(transcript: [TranscriptSegment], context: AdClassificationContext) -> [String: Any] {
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

        let lines = transcript.map { segment in
            String(format: "[%.1f-%.1f] %@", segment.start, segment.end, segment.text)
        }

        let userMessage = (details + ["", "<transcript>"] + lines + ["</transcript>"]).joined(separator: "\n")

        return [
            "model": model,
            "max_tokens": 16000,
            "output_config": [
                "effort": "medium",
                "format": [
                    "type": "json_schema",
                    "schema": outputSchema
                ]
            ],
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": userMessage]
            ]
        ]
    }

    private static let systemPrompt = """
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

    private static let outputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "ads": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "start": ["type": "number"],
                        "end": ["type": "number"],
                        "kind": ["type": "string", "enum": AdSpan.Kind.allCases.map(\.rawValue)],
                        "sponsor": ["type": "string"]
                    ],
                    "required": ["start", "end", "kind", "sponsor"],
                    "additionalProperties": false
                ]
            ]
        ],
        "required": ["ads"],
        "additionalProperties": false
    ]

    // MARK: - Response

    private struct Response: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }

        let content: [Block]
        let stopReason: String?
    }

    private struct ErrorResponse: Decodable {
        struct Detail: Decodable {
            let message: String
        }

        let error: Detail
    }

    private struct ClassifierOutput: Decodable {
        struct Ad: Decodable {
            let start: TimeInterval
            let end: TimeInterval
            let kind: AdSpan.Kind
            let sponsor: String
        }

        let ads: [Ad]
    }
}
