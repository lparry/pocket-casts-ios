import Foundation
import FoundationModels
import PocketCastsUtils

/// Finds the ads on device with Apple's Foundation Models.
///
/// The on-device model has a small context window, so the transcript is sent in overlapping
/// chunks, each in a fresh session, and the spans from every chunk are merged.
@available(iOS 26, *)
struct FoundationModelsAdClassifier: AdClassifier {
    /// Lines repeated at the start of each chunk, so an ad that crosses a boundary is seen whole by one chunk
    static let overlapLines = 4

    private let model: SystemLanguageModel

    init(model: SystemLanguageModel = .default) {
        self.model = model
    }

    var identifier: String {
        "on-device"
    }

    var runsOnDevice: Bool {
        true
    }

    static var isAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    func adSpans(in transcript: [TranscriptSegment], context: AdClassificationContext) async throws -> [AdSpan] {
        guard model.isAvailable else {
            throw AdSkippingError.classifierFailed(Self.unavailableDescription(model.availability))
        }

        let chunks = Self.chunks(of: transcript, characterBudget: Self.characterBudget(contextSize: model.contextSize), overlap: Self.overlapLines)

        var spans: [AdSpan] = []
        var failedChunks = 0
        for chunk in chunks {
            do {
                spans += try await adSpans(inChunk: chunk, context: context, splitsRemaining: 2)
            } catch {
                failedChunks += 1
                FileLog.shared.addMessage("FoundationModelsAdClassifier: skipping a chunk at \(chunk.first?.start ?? 0)s: \(error)")
            }
        }

        if failedChunks == chunks.count, !chunks.isEmpty {
            throw AdSkippingError.classifierFailed("The on-device model couldn't read this transcript")
        }

        return cleanedUp(spans, duration: context.duration)
    }

    /// The on-device context only fits one edge's words, so each gets its own session. An edge that fails is left as it was.
    func boundaryWordIndices(for requests: [AdBoundaryRequest]) async throws -> [Int?] {
        guard model.isAvailable else {
            throw AdSkippingError.classifierFailed(Self.unavailableDescription(model.availability))
        }

        var indices: [Int?] = []
        for request in requests {
            do {
                indices.append(try await boundaryWordIndex(for: request))
            } catch {
                try Task.checkCancellation()
                FileLog.shared.addMessage("FoundationModelsAdClassifier: couldn't place an edge at \(request.edge == .start ? request.ad.start : request.ad.end)s: \(error)")
                indices.append(nil)
            }
        }
        return indices
    }

    private func boundaryWordIndex(for request: AdBoundaryRequest) async throws -> Int? {
        let session = LanguageModelSession(model: model, instructions: AdClassifierPrompt.boundaryInstructions)
        let response = try await session.respond(to: AdClassifierPrompt.boundaryPrompt(for: request),
                                                 generating: OnDeviceAdBoundary.self,
                                                 options: GenerationOptions(samplingMode: .greedy))
        let index = response.content.wordIndex
        return index >= 0 ? index : nil
    }

    /// Classifies one chunk, halving it if the model can't take it all
    private func adSpans(inChunk chunk: [TranscriptSegment], context: AdClassificationContext, splitsRemaining: Int) async throws -> [AdSpan] {
        do {
            let session = LanguageModelSession(model: model, instructions: Self.instructions)
            let response = try await session.respond(to: AdClassifierPrompt.prompt(transcript: chunk, context: context),
                                                     generating: OnDeviceAdList.self,
                                                     options: GenerationOptions(samplingMode: .greedy))
            return response.content.ads.compactMap(\.adSpan)
        } catch {
            guard splitsRemaining > 0, chunk.count > 1 else { throw error }

            let middle = chunk.count / 2
            let firstHalf = try await adSpans(inChunk: Array(chunk[..<middle]), context: context, splitsRemaining: splitsRemaining - 1)
            let secondHalf = try await adSpans(inChunk: Array(chunk[middle...]), context: context, splitsRemaining: splitsRemaining - 1)
            return firstHalf + secondHalf
        }
    }

    private static let instructions = AdClassifierPrompt.instructions + """


    You'll only see part of the episode. Most of an episode is the show itself, so most parts have no ads. Only report \
    clear ads, not the hosts talking about a product, a company or another show as part of the conversation. If an ad \
    runs off the start or end of the part, use the first or last line's time.
    """

    // MARK: - Chunking

    /// How much transcript text fits in a chunk, leaving room for the instructions, schema and response.
    /// English runs at roughly 3–4 characters a token, so this is about a third of the context.
    static func characterBudget(contextSize: Int) -> Int {
        max(1500, contextSize)
    }

    /// Splits the transcript into chunks of at most `characterBudget` characters, each starting with the last `overlap` lines of the one before
    static func chunks(of transcript: [TranscriptSegment], characterBudget: Int, overlap: Int) -> [[TranscriptSegment]] {
        var chunks: [[TranscriptSegment]] = []
        var start = 0

        while start < transcript.count {
            var end = start
            var characters = 0
            while end < transcript.count {
                let length = AdClassifierPrompt.line(for: transcript[end]).count + 1
                if end > start, characters + length > characterBudget {
                    break
                }
                characters += length
                end += 1
            }

            chunks.append(Array(transcript[start..<end]))

            guard end < transcript.count else { break }
            // Always move forward, even when a chunk is shorter than the overlap
            start = max(start + 1, end - overlap)
        }

        return chunks
    }

    private static func unavailableDescription(_ availability: SystemLanguageModel.Availability) -> String {
        guard case .unavailable(let reason) = availability else { return "" }

        switch reason {
        case .deviceNotEligible:
            return "This device can't run Apple Intelligence"
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is turned off"
        case .modelNotReady:
            return "The Apple Intelligence model is still downloading"
        @unknown default:
            return "The on-device model isn't available"
        }
    }
}

@available(iOS 26, *)
@Generable
struct OnDeviceAdList {
    @Guide(description: "Every ad in this part of the transcript, in order")
    var ads: [OnDeviceAd]
}

@available(iOS 26, *)
@Generable
struct OnDeviceAdBoundary {
    @Guide(description: "The index of the ad's first or last word, or -1 if it isn't in these words")
    var wordIndex: Int
}

@available(iOS 26, *)
@Generable
struct OnDeviceAd {
    @Guide(description: "When the ad starts, in seconds, from the start of its first line")
    var start: Double

    @Guide(description: "When the ad ends, in seconds, from the end of its last line")
    var end: Double

    @Guide(description: "What kind of ad it is", .anyOf(AdSpan.Kind.allCases.map(\.rawValue)))
    var kind: String

    @Guide(description: "The advertised brand or show, or an empty string")
    var sponsor: String

    var adSpan: AdSpan? {
        guard let kind = AdSpan.Kind(rawValue: kind), end > start else { return nil }
        return AdSpan(start: start, end: end, kind: kind, sponsor: sponsor)
    }
}
