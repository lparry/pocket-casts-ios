import Foundation
import PocketCastsDataModel
import XCTest
@testable import podcasts

final class OpenRouterAdClassifierTests: XCTestCase {
    private let transcript = [
        TranscriptSegment(start: 0, end: 4.5, text: "Welcome back to the show."),
        TranscriptSegment(start: 4.5, end: 30, text: "This episode is brought to you by Acme."),
        TranscriptSegment(start: 30, end: 40, text: "Now, where were we?")
    ]

    private let context = AdClassificationContext(podcastTitle: "The Show", episodeTitle: "Episode 1", duration: 100)

    override func tearDown() {
        OpenRouterURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testSendsTranscriptToOpenRouterAndParsesSpans() async throws {
        var receivedRequest: URLRequest?
        var receivedBody: [String: Any]?
        OpenRouterURLProtocol.requestHandler = { request in
            receivedRequest = request
            receivedBody = try JSONSerialization.jsonObject(with: request.bodyData) as? [String: Any]
            return Self.success(ads: [
                ["start": 4.5, "end": 30, "kind": "host_read", "sponsor": "Acme"]
            ])
        }

        let spans = try await makeClassifier().adSpans(in: transcript, context: context)

        XCTAssertEqual(spans, [AdSpan(start: 4.5, end: 30, kind: .hostRead, sponsor: "Acme")])

        let request = try XCTUnwrap(receivedRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")

        let body = try XCTUnwrap(receivedBody)
        XCTAssertEqual(body["model"] as? String, "test/model")
        let responseFormat = try XCTUnwrap(body["response_format"] as? [String: Any])
        XCTAssertEqual(responseFormat["type"] as? String, "json_schema")
        XCTAssertEqual((responseFormat["json_schema"] as? [String: Any])?["strict"] as? Bool, true)

        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user"])
        let prompt = try XCTUnwrap(messages.last?["content"] as? String)
        XCTAssertTrue(prompt.contains("Podcast: The Show"))
        XCTAssertTrue(prompt.contains("[4.5-30.0] This episode is brought to you by Acme."))
    }

    func testAsksForEveryBoundaryWordInOneRequest() async throws {
        var requestCount = 0
        var receivedBody: [String: Any]?
        OpenRouterURLProtocol.requestHandler = { request in
            requestCount += 1
            receivedBody = try JSONSerialization.jsonObject(with: request.bodyData) as? [String: Any]
            return Self.success(content: #"{"edges": [{"id": 1, "word_index": 0}, {"id": 0, "word_index": 1}, {"id": 7, "word_index": 0}]}"#)
        }
        let ad = AdSpan(start: 79.3, end: 107.7, kind: .inserted, sponsor: "Bank")
        let requests = [
            AdBoundaryRequest(edge: .start, ad: ad, words: [TimedWord(start: 76.3, end: 77, text: "courtroom."), TimedWord(start: 79.32, end: 79.62, text: "Your")], context: context),
            AdBoundaryRequest(edge: .end, ad: ad, words: [TimedWord(start: 107, end: 107.7, text: "Australia.")], context: context),
            AdBoundaryRequest(edge: .start, ad: ad, words: [TimedWord(start: 110.3, end: 110.6, text: "Full")], context: context)
        ]

        let indices = try await makeClassifier().boundaryWordIndices(for: requests)

        // Answers are matched by id, and an edge without an answer is nil
        XCTAssertEqual(indices, [1, 0, nil])
        XCTAssertEqual(requestCount, 1)
        let prompt = try XCTUnwrap((receivedBody?["messages"] as? [[String: Any]])?.last?["content"] as? String)
        XCTAssertTrue(prompt.contains("<edge id=\"0\">\nWhich word starts this ad?"))
        XCTAssertTrue(prompt.contains("1 [79.32] Your"))
        XCTAssertTrue(prompt.contains("<edge id=\"1\">\nWhich word ends this ad?"))
    }

    func testCleansUpSpans() async throws {
        OpenRouterURLProtocol.requestHandler = { _ in
            Self.success(ads: [
                ["start": 60, "end": 120, "kind": "inserted", "sponsor": ""],
                ["start": 10, "end": 30, "kind": "host_read", "sponsor": "Acme"],
                ["start": 25, "end": 40, "kind": "host_read", "sponsor": "Acme"],
                ["start": 50, "end": 51, "kind": "self_promo", "sponsor": ""]
            ])
        }

        let spans = try await makeClassifier().adSpans(in: transcript, context: context)

        XCTAssertEqual(spans, [
            AdSpan(start: 10, end: 40, kind: .hostRead, sponsor: "Acme"),
            AdSpan(start: 60, end: 100, kind: .inserted, sponsor: nil)
        ])
    }

    func testThrowsOnHTTPErrors() async {
        OpenRouterURLProtocol.requestHandler = { request in
            let body = #"{"error":{"code":401,"message":"No auth credentials found"}}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }

        do {
            _ = try await makeClassifier().adSpans(in: transcript, context: context)
            XCTFail("Expected the request to throw")
        } catch {
            XCTAssertEqual(error.localizedDescription, "OpenRouter error: No auth credentials found")
            XCTAssertTrue(AdSkippingError.isRetryable(error))
        }
    }

    func testThrowsOnUpstreamErrorsReturnedWithA200() async {
        OpenRouterURLProtocol.requestHandler = { request in
            let body = #"{"error":{"code":502,"message":"Provider returned error"}}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }

        do {
            _ = try await makeClassifier().adSpans(in: transcript, context: context)
            XCTFail("Expected the request to throw")
        } catch {
            XCTAssertEqual(error.localizedDescription, "OpenRouter error: Provider returned error")
            XCTAssertTrue(AdSkippingError.isRetryable(error))
        }
    }

    func testThrowsWhenTheResponseIsCutOff() async {
        OpenRouterURLProtocol.requestHandler = { request in
            let body = #"{"choices":[{"message":{"content":"{\"ads\": ["},"finish_reason":"length"}]}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }

        do {
            _ = try await makeClassifier().adSpans(in: transcript, context: context)
            XCTFail("Expected the request to throw")
        } catch {
            XCTAssertEqual(error.localizedDescription, "The model's response was cut off")
            XCTAssertFalse(AdSkippingError.isRetryable(error))
        }
    }

    func testOnlyRetriesStatusCodesThatMayClearUp() {
        for statusCode in [401, 402, 408, 429, 500, 502, 503, 504] {
            XCTAssertTrue(OpenRouterAdClassifier.isRetryable(statusCode: statusCode), "\(statusCode)")
        }
        for statusCode in [400, 403, 404, 413, 422] {
            XCTAssertFalse(OpenRouterAdClassifier.isRetryable(statusCode: statusCode), "\(statusCode)")
        }
    }

    func testTreatsOtherClientErrorsAsAnAnswerThatCantBeUsed() async {
        OpenRouterURLProtocol.requestHandler = { request in
            let body = #"{"error":{"code":404,"message":"No endpoints found that can handle the requested parameters."}}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }

        do {
            _ = try await makeClassifier().adSpans(in: transcript, context: context)
            XCTFail("Expected the request to throw")
        } catch {
            XCTAssertEqual(error.localizedDescription, "OpenRouter error: No endpoints found that can handle the requested parameters.")
            XCTAssertFalse(AdSkippingError.isRetryable(error))
            XCTAssertTrue(AdSkippingError.isPermanent(error))
        }
    }

    func testClassifiesUpstreamErrorsReturnedWithA200ByTheirCode() async {
        OpenRouterURLProtocol.requestHandler = { request in
            let body = #"{"error":{"code":400,"message":"This model's maximum context length is 200000 tokens"}}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }

        do {
            _ = try await makeClassifier().adSpans(in: transcript, context: context)
            XCTFail("Expected the request to throw")
        } catch {
            XCTAssertFalse(AdSkippingError.isRetryable(error))
            XCTAssertTrue(AdSkippingError.isPermanent(error))
        }
    }

    func testTreatsErrorsWithAnUnreadableCodeAsTemporary() async {
        OpenRouterURLProtocol.requestHandler = { request in
            let body = #"{"error":{"code":"provider_error","message":"Provider returned error"}}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }

        do {
            _ = try await makeClassifier().adSpans(in: transcript, context: context)
            XCTFail("Expected the request to throw")
        } catch {
            XCTAssertEqual(error.localizedDescription, "OpenRouter error: Provider returned error")
            XCTAssertTrue(AdSkippingError.isRetryable(error))
        }
    }

    // MARK: - Helpers

    private func makeClassifier() -> OpenRouterAdClassifier {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenRouterURLProtocol.self]
        return OpenRouterAdClassifier(apiKey: "test-key", model: "test/model", session: URLSession(configuration: configuration))
    }

    private static func success(ads: [[String: Any]]) -> (HTTPURLResponse, Data) {
        let output = try! JSONSerialization.data(withJSONObject: ["ads": ads])
        return success(content: String(decoding: output, as: UTF8.self))
    }

    private static func success(content: String) -> (HTTPURLResponse, Data) {
        let body: [String: Any] = [
            "choices": [
                ["message": ["role": "assistant", "content": content], "finish_reason": "stop"]
            ]
        ]
        let response = HTTPURLResponse(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (response, try! JSONSerialization.data(withJSONObject: body))
    }
}

@available(iOS 26, *)
final class FoundationModelsAdClassifierChunkingTests: XCTestCase {
    private let transcript = (0..<10).map { index in
        TranscriptSegment(start: Double(index * 10), end: Double(index * 10 + 10), text: String(repeating: "a", count: 80))
    }

    func testFitsEachChunkInTheBudgetAndOverlapsThem() {
        // Each line is about 93 characters, so three fit in 300
        let chunks = FoundationModelsAdClassifier.chunks(of: transcript, characterBudget: 300, overlap: 1)

        XCTAssertEqual(chunks.map { $0.map(\.start) }, [
            [0, 10, 20],
            [20, 30, 40],
            [40, 50, 60],
            [60, 70, 80],
            [80, 90]
        ])
    }

    func testKeepsTheWholeTranscriptInOneChunkWhenItFits() {
        let chunks = FoundationModelsAdClassifier.chunks(of: transcript, characterBudget: 10_000, overlap: 4)

        XCTAssertEqual(chunks, [transcript])
    }

    func testAlwaysMovesForwardWhenLinesAreLongerThanTheBudget() {
        let chunks = FoundationModelsAdClassifier.chunks(of: transcript, characterBudget: 10, overlap: 4)

        XCTAssertEqual(chunks.count, transcript.count)
        XCTAssertEqual(chunks.map(\.count), Array(repeating: 1, count: transcript.count))
    }
}

final class AdSkippingScanOrderTests: XCTestCase {
    func testScansUpNextFirstThenTheRestInOrder() {
        let order = AdSkippingManager.scanOrder(downloaded: ["new", "playing", "older", "next"], upNext: ["playing", "streamed", "next"])

        XCTAssertEqual(order, ["playing", "next", "new", "older"])
    }

    func testKeepsTheDownloadOrderWithoutUpNext() {
        XCTAssertEqual(AdSkippingManager.scanOrder(downloaded: ["a", "b", "c"], upNext: []), ["a", "b", "c"])
    }
}

final class AdSkippingPlaybackTests: XCTestCase {
    private let spans = [
        AdSpan(start: 10, end: 40, kind: .hostRead, sponsor: "Acme"),
        AdSpan(start: 100, end: 130, kind: .selfPromo, sponsor: nil)
    ]

    private let allKinds = Set(AdSpan.Kind.allCases)

    func testSkipsTheAdThatContainsTheTime() {
        XCTAssertEqual(AdSkippingManager.adSkip(in: spans, at: 12, skipping: allKinds, restored: []), AdSkip(spans: [spans[0]]))
        XCTAssertNil(AdSkippingManager.adSkip(in: spans, at: 50, skipping: allKinds, restored: []))
    }

    func testOnlySkipsTheChosenKinds() {
        XCTAssertNil(AdSkippingManager.adSkip(in: spans, at: 110, skipping: [.hostRead], restored: []))
        XCTAssertEqual(AdSkippingManager.adSkip(in: spans, at: 110, skipping: [.selfPromo], restored: [])?.spans, [spans[1]])
    }

    func testDoesntSkipRestoredAdsOrTheLastSecond() {
        XCTAssertNil(AdSkippingManager.adSkip(in: spans, at: 12, skipping: allKinds, restored: [spans[0]]))
        XCTAssertNil(AdSkippingManager.adSkip(in: spans, at: 39.5, skipping: allKinds, restored: []))
    }

    func testJoinsAdsInTheSameBreak() {
        // Gaps like these, full of jingles and pauses, came from a real episode
        let adBreak = [
            AdSpan(start: 79.3, end: 107.7, kind: .inserted, sponsor: "Bank"),
            AdSpan(start: 110.3, end: 168.4, kind: .hostRead, sponsor: "Insurer"),
            AdSpan(start: 174.6, end: 200, kind: .inserted, sponsor: "Coffee"),
            AdSpan(start: 640.5, end: 668.7, kind: .inserted, sponsor: "Bank")
        ]

        let skip = AdSkippingManager.adSkip(in: adBreak, at: 80, skipping: allKinds, restored: [])

        XCTAssertEqual(skip?.spans, Array(adBreak[0...2]))
        XCTAssertEqual(skip?.end, 200)
    }

    func testStopsJoiningAtAnAdThatIsntSkipped() {
        let adBreak = [
            AdSpan(start: 10, end: 40, kind: .inserted, sponsor: nil),
            AdSpan(start: 42, end: 60, kind: .selfPromo, sponsor: nil),
            AdSpan(start: 62, end: 90, kind: .inserted, sponsor: nil)
        ]

        XCTAssertEqual(AdSkippingManager.adSkip(in: adBreak, at: 20, skipping: [.inserted], restored: [])?.end, 40)
    }

    func testPlaysAPreviewedAdThroughOnceOnly() {
        let ad = AdSpan(start: 100, end: 130, kind: .inserted, sponsor: nil)

        XCTAssertEqual(AdSkippingManager.preview(ad, at: 0), ad, "Kept while the episode loads")
        XCTAssertEqual(AdSkippingManager.preview(ad, at: 97), ad)
        XCTAssertEqual(AdSkippingManager.preview(ad, at: 129.9), ad)
        XCTAssertNil(AdSkippingManager.preview(ad, at: 130), "Skipped again once it has played")
        XCTAssertNil(AdSkippingManager.preview(nil, at: 100))
    }
}

final class AdClassifierFallbackTests: XCTestCase {
    private let transcript = [TranscriptSegment(start: 0, end: 600, text: "The whole show.")]
    private let context = AdClassificationContext(podcastTitle: nil, episodeTitle: nil, duration: 600)
    private let ad = AdSpan(start: 10, end: 40, kind: .inserted, sponsor: nil)

    func testUsesTheFirstClassifierThatAnswers() async throws {
        let backup = StubClassifier(identifier: "backup") { [] }
        let result = try await AdSkippingManager.classify(transcript, context: context, using: [StubClassifier(identifier: "first") { [self.ad] }, backup])

        XCTAssertEqual(result.classifier.identifier, "first")
        XCTAssertEqual(result.spans, [ad])
        XCTAssertFalse(result.isSuspect)
        XCTAssertEqual(backup.calls.count, 0)
    }

    func testFallsBackWhenTheAnswerCantBeUsed() async throws {
        let failing = StubClassifier(identifier: "first") { throw AdSkippingError.classifierFailed("Cut off") }
        let result = try await AdSkippingManager.classify(transcript, context: context, using: [failing, StubClassifier(identifier: "backup") { [self.ad] }])

        XCTAssertEqual(result.classifier.identifier, "backup")
    }

    func testDoesntFallBackWhenTheClassifierCantBeReached() async {
        let backup = StubClassifier(identifier: "backup") { [] }
        let classifiers = [
            StubClassifier(identifier: "offline") { throw URLError(.notConnectedToInternet) },
            StubClassifier(identifier: "unauthorised") { throw AdSkippingError.classifierUnavailable("OpenRouter error: No auth credentials found") }
        ]

        for classifier in classifiers {
            do {
                _ = try await AdSkippingManager.classify(transcript, context: context, using: [classifier, backup])
                XCTFail("Expected \(classifier.identifier) to throw")
            } catch {
                XCTAssertTrue(AdSkippingError.isRetryable(error))
            }
        }
        XCTAssertEqual(backup.calls.count, 0)
    }

    func testKeepsAnImplausibleAnswerAsSuspectRatherThanFallingBack() async throws {
        let tooMany = (0..<3).map { AdSpan(start: Double($0) * 200, end: Double($0) * 200 + 150, kind: .inserted, sponsor: nil) }
        let backup = StubClassifier(identifier: "backup") { [self.ad] }
        let result = try await AdSkippingManager.classify(transcript, context: context, using: [StubClassifier(identifier: "first") { tooMany }, backup])

        XCTAssertEqual(result.classifier.identifier, "first")
        XCTAssertTrue(result.isSuspect)
        XCTAssertEqual(backup.calls.count, 0)
    }

    private final class Calls {
        var count = 0
    }

    private struct StubClassifier: AdClassifier {
        let identifier: String
        let answer: () throws -> [AdSpan]
        let calls = Calls()

        init(identifier: String, answer: @escaping () throws -> [AdSpan]) {
            self.identifier = identifier
            self.answer = answer
        }

        func adSpans(in transcript: [TranscriptSegment], context: AdClassificationContext) async throws -> [AdSpan] {
            calls.count += 1
            return try answer()
        }

        func boundaryWordIndices(for requests: [AdBoundaryRequest]) async throws -> [Int?] {
            requests.map { _ in nil }
        }
    }
}

final class AdPlausibilityTests: XCTestCase {
    func testDropsAdsTooShortForTheirKind() {
        let spans = [
            AdSpan(start: 0, end: 6, kind: .hostRead, sponsor: nil),
            AdSpan(start: 10, end: 24.3, kind: .inserted, sponsor: nil),
            AdSpan(start: 30, end: 37, kind: .crossPromo, sponsor: nil),
            AdSpan(start: 40, end: 45.2, kind: .selfPromo, sponsor: nil),
            AdSpan(start: 50, end: 54, kind: .selfPromo, sponsor: nil)
        ]

        let cleaned = OpenRouterAdClassifier(apiKey: "", model: "").cleanedUp(spans, duration: 100)

        XCTAssertEqual(cleaned.map(\.start), [10, 40])
    }

    func testShortFalsePositivesCantJoinIntoABreak() {
        // Two real ads 10s apart, with a 6s "host read" between them that would otherwise bridge the gap
        let spans = [
            AdSpan(start: 0, end: 30, kind: .inserted, sponsor: nil),
            AdSpan(start: 33, end: 39, kind: .hostRead, sponsor: nil),
            AdSpan(start: 40, end: 70, kind: .inserted, sponsor: nil)
        ]

        let cleaned = OpenRouterAdClassifier(apiKey: "", model: "").cleanedUp(spans, duration: 100)
        let skip = AdSkippingManager.adSkip(in: cleaned, at: 5, skipping: Set(AdSpan.Kind.allCases), restored: [])

        XCTAssertEqual(skip?.end, 30)
    }

    func testFlagsImplausibleResults() {
        func ads(_ count: Int, each length: TimeInterval) -> [AdSpan] {
            (0..<count).map { AdSpan(start: Double($0) * 100, end: Double($0) * 100 + length, kind: .inserted, sponsor: nil) }
        }

        // A real 26 minute news episode: 8 ads, 23% of it
        XCTAssertFalse(EpisodeAdAnalysis.looksWrong(ads(8, each: 44.5), duration: 1560))
        // Half the episode
        XCTAssertTrue(EpisodeAdAnalysis.looksWrong(ads(3, each: 300), duration: 1800))
        // 54 ads in 45 minutes
        XCTAssertTrue(EpisodeAdAnalysis.looksWrong(ads(54, each: 6), duration: 2700))
        // A few ads in a short episode isn't too many an hour
        XCTAssertFalse(EpisodeAdAnalysis.looksWrong(ads(3, each: 15), duration: 600))
    }

    func testRemembersSuspectAnalyses() throws {
        var analysis = EpisodeAdAnalysis(version: EpisodeAdAnalysis.currentVersion, episodeUuid: "e", analyzedAt: Date(), classifier: "on-device", audioFileSize: 1, transcriptSegmentCount: 1, spans: [])
        XCTAssertFalse(analysis.isSuspect)
        analysis.isSuspect = true
        let decoded = try JSONDecoder().decode(EpisodeAdAnalysis.self, from: JSONEncoder().encode(analysis))
        XCTAssertTrue(decoded.isSuspect)
    }
}

final class TranscriptLineTests: XCTestCase {
    func testBreaksLinesAtSentencesPausesAndTheMaximumLength() {
        let words = [
            TimedWord(start: 0, end: 0.5, text: "Hello"),
            TimedWord(start: 0.5, end: 1, text: "there."),
            TimedWord(start: 1.1, end: 1.5, text: "We'll"),
            TimedWord(start: 1.5, end: 2, text: "be"),
            // A pause before the next word
            TimedWord(start: 3, end: 3.5, text: "right"),
            TimedWord(start: 3.5, end: 6, text: "back"),
            TimedWord(start: 6, end: 9, text: "after"),
            TimedWord(start: 9, end: 9.5, text: "this")
        ]

        let lines = TranscriptSegment.lines(from: words, maxDuration: 5, pause: 0.5)

        XCTAssertEqual(lines.map(\.text), ["Hello there.", "We'll be", "right back", "after this"])
        XCTAssertEqual(lines.map(\.start), [0, 1.1, 3, 6])
        XCTAssertEqual(lines.map(\.end), [1, 2, 6, 9.5])
        XCTAssertEqual(lines[1].words, Array(words[2...3]))
    }
}

final class AdBoundaryRefinerTests: XCTestCase {
    private let words = (0..<60).map { index in
        TimedWord(start: Double(index), end: Double(index) + 0.8, text: "word\(index)")
    }

    private let context = AdClassificationContext(podcastTitle: nil, episodeTitle: nil, duration: 60)

    func testShowsTheWordsAroundEachEdge() {
        let window = AdBoundaryRefiner.window(around: 30, in: words)

        XCTAssertEqual(window.first?.start, 15)
        XCTAssertEqual(window.last?.start, 45)
    }

    func testMovesEdgesOntoTheChosenWords() async throws {
        // Picks the word 3 before each edge's window midpoint for the start, and the one 2 after for the end
        let classifier = FakeClassifier { request in
            let middle = request.words.firstIndex { $0.start >= (request.edge == .start ? request.ad.start : request.ad.end) } ?? 0
            return request.edge == .start ? middle - 3 : middle + 2
        }

        let spans = [AdSpan(start: 20, end: 40, kind: .inserted, sponsor: nil), AdSpan(start: 45, end: 55, kind: .hostRead, sponsor: nil)]

        let refined = try await AdBoundaryRefiner(classifier: classifier).refine(spans, words: words, context: context)

        XCTAssertEqual(refined, [AdSpan(start: 17, end: 42.8, kind: .inserted, sponsor: nil), AdSpan(start: 42, end: 57.8, kind: .hostRead, sponsor: nil)])
        // Every edge goes in one request
        XCTAssertEqual(classifier.requestCounter.count, 1)
    }

    func testKeepsEdgesTheClassifierCantPlace() async throws {
        let span = AdSpan(start: 20, end: 40, kind: .inserted, sponsor: nil)

        let notFound = try await AdBoundaryRefiner(classifier: FakeClassifier { _ in nil }).refine([span], words: words, context: context)
        let outOfRange = try await AdBoundaryRefiner(classifier: FakeClassifier { _ in 500 }).refine([span], words: words, context: context)
        let failing = try await AdBoundaryRefiner(classifier: FakeClassifier { _ in throw AdSkippingError.classifierFailed("Cut off") }).refine([span], words: words, context: context)

        XCTAssertEqual(notFound, [span])
        XCTAssertEqual(outOfRange, [span])
        XCTAssertEqual(failing, [span])
    }

    func testThrowsWhenTheClassifierCantBeReached() async {
        let span = AdSpan(start: 20, end: 40, kind: .inserted, sponsor: nil)

        do {
            _ = try await AdBoundaryRefiner(classifier: FakeClassifier { _ in throw URLError(.notConnectedToInternet) }).refine([span], words: words, context: context)
            XCTFail("Expected refining to throw")
        } catch {
            XCTAssertTrue(AdSkippingError.isRetryable(error))
        }
    }

    private final class Counter {
        var count = 0
    }

    private struct FakeClassifier: AdClassifier {
        let boundary: (AdBoundaryRequest) throws -> Int?
        var requestCounter = Counter()

        var identifier: String {
            "fake"
        }

        func adSpans(in transcript: [TranscriptSegment], context: AdClassificationContext) async throws -> [AdSpan] {
            []
        }

        func boundaryWordIndices(for requests: [AdBoundaryRequest]) async throws -> [Int?] {
            requestCounter.count += 1
            return try requests.map(boundary)
        }
    }
}

final class AudioBoundarySnapperTests: XCTestCase {
    /// Levels in 20ms blocks, starting at 0s
    private func levels(_ stretches: [(seconds: Double, level: Float)]) -> [Float] {
        stretches.flatMap { Array(repeating: $0.level, count: Int(($0.seconds / 0.02).rounded())) }
    }

    func testMovesAnEndEdgeOntoTheSilenceAfterIt() {
        // Ad speech, a jingle, then silence from 2.5s to 3s
        let levels = levels([(2, -20), (0.5, -15), (0.5, -70), (1, -20)])

        let snapped = AudioBoundarySnapper.snappedTime(near: 2, allowed: 2...4, levels: levels, levelsStart: 0)

        XCTAssertEqual(snapped ?? 0, 2.75, accuracy: 0.01)
    }

    func testNeverMovesAnEdgeInwards() {
        // Silence only before an end edge, which would cut the ad short
        let levels = levels([(1, -20), (0.5, -70), (2.5, -20)])

        XCTAssertNil(AudioBoundarySnapper.snappedTime(near: 2, allowed: 2...4, levels: levels, levelsStart: 0))
    }

    func testFallsBackToASuddenChangeInLoudness() {
        // A jingle starts at 1.5s, with no silence anywhere
        let levels = levels([(1.5, -38), (2.5, -14)])

        let snapped = AudioBoundarySnapper.snappedTime(near: 2, allowed: 0...2, levels: levels, levelsStart: 0)

        XCTAssertEqual(snapped ?? 0, 1.5, accuracy: 0.01)
    }

    func testLeavesEdgesWithNothingNearby() {
        XCTAssertNil(AudioBoundarySnapper.snappedTime(near: 2, allowed: 0...4, levels: levels([(4, -20)]), levelsStart: 0))
    }

    func testStaysBetweenTheNeighbouringWords() {
        let span = AdSpan(start: 10, end: 20, kind: .inserted, sponsor: nil)
        let words = [
            TimedWord(start: 8, end: 9, text: "show"),
            TimedWord(start: 10, end: 11, text: "ad"),
            TimedWord(start: 19, end: 20, text: "ad"),
            TimedWord(start: 21, end: 22, text: "show")
        ]

        XCTAssertEqual(AudioBoundarySnapper.startRange(for: span, words: words), 9...10)
        XCTAssertEqual(AudioBoundarySnapper.endRange(for: span, words: words), 20...21)
    }
}

final class AdSkippingPodcastSettingTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "AdSkippingUnscannedPodcasts")
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "AdSkippingUnscannedPodcasts")
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    @MainActor
    func testScansEveryPodcastUntilOneIsTurnedOff() {
        let manager = AdSkippingManager(store: AdSpanStore(directory: directory))
        XCTAssertTrue(manager.isScanning(podcastUuid: "podcast"))

        manager.setScanning(false, podcastUuid: "podcast")
        XCTAssertFalse(manager.isScanning(podcastUuid: "podcast"))
        XCTAssertTrue(manager.isScanning(podcastUuid: "other"))

        let episode = Episode()
        episode.podcastUuid = "podcast"
        XCTAssertFalse(manager.isScanning(episode))
        XCTAssertTrue(manager.isScanning(UserEpisode()))

        // Remembered across launches
        XCTAssertFalse(AdSkippingManager(store: AdSpanStore(directory: directory)).isScanning(podcastUuid: "podcast"))

        manager.setScanning(true, podcastUuid: "podcast")
        XCTAssertTrue(manager.isScanning(podcastUuid: "podcast"))
    }
}

final class TranscriptStoreTests: XCTestCase {
    private var directory: URL!

    private let transcript = [
        TranscriptSegment(start: 0, end: 1, text: "Hello there.", words: [TimedWord(start: 0, end: 0.5, text: "Hello"), TimedWord(start: 0.5, end: 1, text: "there.")])
    ]

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testReusesTheTranscriptForTheSameFile() throws {
        try TranscriptStore(directory: directory).save(transcript, for: "episode", audioFileSize: 100, audioDuration: 1)

        let saved = TranscriptStore(directory: directory).transcript(for: "episode", audioFileSize: 100)

        XCTAssertEqual(saved?.segments, transcript)
        XCTAssertEqual(saved?.audioDuration, 1)
    }

    func testIgnoresTheTranscriptOfADifferentDownload() throws {
        let store = TranscriptStore(directory: directory)
        try store.save(transcript, for: "episode", audioFileSize: 100, audioDuration: 1)

        XCTAssertNil(store.transcript(for: "episode", audioFileSize: 200))
    }

    func testDeletesTranscriptsOfEpisodesThatArentDownloaded() throws {
        let store = TranscriptStore(directory: directory)
        try store.save(transcript, for: "kept", audioFileSize: 100, audioDuration: 1)
        try store.save(transcript, for: "deleted", audioFileSize: 100, audioDuration: 1)

        store.removeAll(except: ["kept"])

        XCTAssertNotNil(store.transcript(for: "kept", audioFileSize: 100))
        XCTAssertNil(store.transcript(for: "deleted", audioFileSize: 100))
    }

    func testKnowsWhichFileWasTranscribedWithoutReadingIt() throws {
        let store = TranscriptStore(directory: directory)
        try store.save(transcript, for: "episode", audioFileSize: 100, audioDuration: 1)

        XCTAssertTrue(store.hasTranscript(for: "episode", audioFileSize: 100))
        XCTAssertFalse(store.hasTranscript(for: "episode", audioFileSize: 200))
        XCTAssertFalse(store.hasTranscript(for: "other", audioFileSize: 100))
    }

    func testOnlyKeepsTheTranscriptOfTheLatestDownload() throws {
        let store = TranscriptStore(directory: directory)
        try store.save(transcript, for: "episode", audioFileSize: 100, audioDuration: 1)
        try store.save(transcript, for: "episode", audioFileSize: 200, audioDuration: 1)

        XCTAssertFalse(store.hasTranscript(for: "episode", audioFileSize: 100))
        XCTAssertNotNil(store.transcript(for: "episode", audioFileSize: 200))
    }

    func testMovesTranscriptsSavedWithoutTheFileSizeInTheirName() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy: [String: Any] = ["formatVersion": TranscriptStore.formatVersion, "audioFileSize": 100, "audioDuration": 1, "segments": [["start": 0, "end": 1, "text": "Hello there.", "words": []]]]
        try JSONSerialization.data(withJSONObject: legacy).write(to: directory.appendingPathComponent("episode.json"))
        try Data("not a transcript".utf8).write(to: directory.appendingPathComponent("broken.json"))

        let store = TranscriptStore(directory: directory)
        store.migrateLegacyFiles()

        XCTAssertTrue(store.hasTranscript(for: "episode", audioFileSize: 100))
        XCTAssertFalse(store.hasTranscript(for: "episode", audioFileSize: 200))
        XCTAssertEqual(store.transcript(for: "episode", audioFileSize: 100)?.segments.first?.text, "Hello there.")
        XCTAssertFalse(store.hasTranscript(for: "broken", audioFileSize: nil))
    }
}

final class AdScanTimingsTests: XCTestCase {
    func testShowsStepsUnderAMinuteInSeconds() {
        XCTAssertTrue(AdZappingDetails.formatTimeTaken(0.04).contains("0"))
        XCTAssertFalse(AdZappingDetails.formatTimeTaken(0.4).contains(":"), "Not rounded to 0:00")
        XCTAssertTrue(AdZappingDetails.formatTimeTaken(0.4).contains("0.4"))
        XCTAssertTrue(AdZappingDetails.formatTimeTaken(12.3).contains("12"))
        XCTAssertTrue(AdZappingDetails.formatTimeTaken(65).contains(":"))
    }

    func testReadsTimingsSavedBeforeEdgesWereCounted() throws {
        let json = #"{"audioDuration":1800,"transcription":60,"firstPass":20,"edgePass":8,"audioSnapping":0.2}"#

        let timings = try JSONDecoder().decode(AdScanTimings.self, from: Data(json.utf8))

        XCTAssertEqual(timings.audioSnapping, 0.2)
        XCTAssertNil(timings.snappedEdges)
        XCTAssertNil(timings.edgeCount)
        XCTAssertNil(timings.audioUnreadable)
    }

    func testSaysWhenTheAudioCouldntBeRead() async {
        let ad = AdSpan(start: 10, end: 40, kind: .inserted, sponsor: nil)

        let result = await AudioBoundarySnapper.snap([ad], words: [], fileURL: URL(fileURLWithPath: "/nonexistent/episode.mp3"))

        XCTAssertFalse(result.couldReadFile)
        XCTAssertEqual(result.movedEdges, 0)
        XCTAssertEqual(result.spans, [ad])
    }
}

final class AdScanLimitTests: XCTestCase {
    private let charging = AdSkippingManager.ScanConditions(isCharging: true, isLowPowerMode: false, isHot: false)
    private let onBattery = AdSkippingManager.ScanConditions(isCharging: false, isLowPowerMode: false, isHot: false)
    private let lowPower = AdSkippingManager.ScanConditions(isCharging: false, isLowPowerMode: true, isHot: false)
    private let hot = AdSkippingManager.ScanConditions(isCharging: true, isLowPowerMode: false, isHot: true)

    func testWindowIsThePlayingEpisodeAndTheTopOfUpNext() {
        XCTAssertEqual(AdSkippingManager.detectionWindow(nowPlaying: "playing", upNext: ["a", "b", "c", "d"], limit: 3), ["playing", "a", "b", "c"])
        XCTAssertEqual(AdSkippingManager.detectionWindow(nowPlaying: nil, upNext: ["a", "b"], limit: 3), ["a", "b"])
        XCTAssertNil(AdSkippingManager.detectionWindow(nowPlaying: "playing", upNext: ["a"], limit: nil), "All downloads")
    }

    func testFindsAdsInTheWindowOnBattery() {
        XCTAssertEqual(plan(inWindow: true, hasTranscript: false, conditions: onBattery), .full)
        XCTAssertEqual(plan(inWindow: true, hasTranscript: true, conditions: onBattery), .full)
    }

    func testOnlyTranscribesOutsideTheWindowWhileCharging() {
        XCTAssertEqual(plan(inWindow: false, hasTranscript: false, conditions: charging), .transcribeOnly)
        XCTAssertEqual(plan(inWindow: false, hasTranscript: false, conditions: onBattery), .waitingForPower)
        XCTAssertEqual(plan(inWindow: false, hasTranscript: true, conditions: charging), .waitingForUpNext)
        XCTAssertEqual(plan(inWindow: false, hasTranscript: true, conditions: onBattery), .waitingForUpNext)
    }

    func testDoesntTranscribeInLowPowerModeOrWhenHot() {
        XCTAssertEqual(plan(inWindow: true, hasTranscript: false, conditions: lowPower), .waitingForPower)
        XCTAssertEqual(plan(inWindow: true, hasTranscript: false, conditions: hot), .waitingForPower)
        XCTAssertEqual(plan(inWindow: false, hasTranscript: false, conditions: hot), .waitingForPower)
        XCTAssertEqual(plan(inWindow: true, hasTranscript: true, conditions: lowPower), .full, "Finding ads in a saved transcript needs no transcribing")
    }

    func testScanningEverythingWithoutAWindow() {
        let inWindow = AdSkippingManager.detectionWindow(nowPlaying: nil, upNext: [], limit: nil)?.contains("anything") ?? true
        XCTAssertEqual(plan(inWindow: inWindow, hasTranscript: false, conditions: onBattery), .full)
    }

    func testAScanTheListenerAskedForIgnoresTheLimits() {
        for conditions in [charging, onBattery, lowPower, hot] {
            XCTAssertEqual(AdSkippingManager.scanPlan(requested: true, inDetectionWindow: false, hasTranscript: false, conditions: conditions), .full)
        }
    }

    private func plan(inWindow: Bool, hasTranscript: Bool, conditions: AdSkippingManager.ScanConditions) -> AdSkippingManager.ScanPlan {
        AdSkippingManager.scanPlan(requested: false, inDetectionWindow: inWindow, hasTranscript: hasTranscript, conditions: conditions)
    }
}

final class AdScanFailureTests: XCTestCase {
    private var directory: URL!

    private let failure = AdScanFailure(audioFileSize: 100, classifiers: "openrouter:test/model,on-device", message: "The model's response was cut off", failedAt: Date(timeIntervalSince1970: 0))

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testPersistsFailuresAcrossInstances() throws {
        try AdScanFailureStore(directory: directory).save(failure, for: "episode")

        XCTAssertEqual(AdScanFailureStore(directory: directory).failure(for: "episode"), failure)
    }

    func testOnlyMatchesTheSameFileAndClassifiers() {
        XCTAssertTrue(failure.matches(audioFileSize: 100, classifiers: "openrouter:test/model,on-device"))
        XCTAssertFalse(failure.matches(audioFileSize: 200, classifiers: "openrouter:test/model,on-device"), "A re-download is tried again")
        XCTAssertFalse(failure.matches(audioFileSize: 100, classifiers: "openrouter:other/model,on-device"), "A different model is tried again")
        XCTAssertFalse(failure.matches(audioFileSize: 100, classifiers: "openrouter:test/model"), "Losing the backup is tried again")
    }

    func testIdentifiesClassifiersByModel() {
        let classifiers: [AdClassifier] = [OpenRouterAdClassifier(apiKey: "key", model: "test/model")]

        XCTAssertEqual(AdSkippingManager.classifiersKey(classifiers), "openrouter:test/model")
        XCTAssertNotEqual(AdSkippingManager.classifiersKey(classifiers), AdSkippingManager.classifiersKey([OpenRouterAdClassifier(apiKey: "key", model: "other/model")]))
    }

    func testRemovesFailures() throws {
        let store = AdScanFailureStore(directory: directory)
        try store.save(failure, for: "kept")
        try store.save(failure, for: "rescanned")
        try store.save(failure, for: "deleted")

        store.remove("rescanned")
        store.removeAll(except: ["kept", "rescanned"])

        XCTAssertNotNil(store.failure(for: "kept"))
        XCTAssertNil(store.failure(for: "rescanned"))
        XCTAssertNil(store.failure(for: "deleted"))
    }

    func testOnlyRemembersFailuresThatWouldHappenAgain() {
        XCTAssertTrue(AdSkippingError.isPermanent(AdSkippingError.classifierFailed("Cut off")))
        XCTAssertTrue(AdSkippingError.isPermanent(AdSkippingError.emptyTranscript))
        XCTAssertTrue(AdSkippingError.isPermanent(AdSkippingError.unsupportedLocale(Locale(identifier: "xx"))))

        XCTAssertFalse(AdSkippingError.isPermanent(AdSkippingError.classifierUnavailable("Rate limited")))
        XCTAssertFalse(AdSkippingError.isPermanent(URLError(.notConnectedToInternet)))
        XCTAssertFalse(AdSkippingError.isPermanent(AdSkippingError.notDownloaded))
        XCTAssertFalse(AdSkippingError.isPermanent(AdSkippingError.noClassifier))
        XCTAssertFalse(AdSkippingError.isPermanent(CocoaError(.fileReadUnknown)), "Unexpected errors aren't remembered")
    }
}

final class AdTranscriptExcerptTests: XCTestCase {
    private let words = [
        TimedWord(start: 0, end: 1, text: "Before"),
        TimedWord(start: 7, end: 8, text: "anyway."),
        TimedWord(start: 9.6, end: 10.2, text: "Brought"),
        TimedWord(start: 10.2, end: 11, text: "to"),
        TimedWord(start: 11, end: 12, text: "you"),
        TimedWord(start: 29, end: 30.6, text: "Acme."),
        TimedWord(start: 31, end: 32, text: "Back"),
        TimedWord(start: 40, end: 41, text: "later")
    ]

    func testTakesTheWordsWhoseMiddleIsInTheAdWithAFewSecondsEitherSide() {
        let ad = AdSpan(start: 10, end: 30, kind: .hostRead, sponsor: "Acme")

        let excerpts = AdSkippingManager.adTranscripts(of: [ad], in: [TranscriptSegment(start: 0, end: 41, text: "", words: words)])

        XCTAssertEqual(excerpts[ad], AdTranscriptExcerpt(before: "anyway. Brought", ad: "to you Acme.", after: "Back"))
    }

    func testUsesWholeLinesWithoutWordTimings() {
        let transcript = [
            TranscriptSegment(start: 0, end: 10, text: "The show."),
            TranscriptSegment(start: 10, end: 20, text: "This episode is brought to you by Acme."),
            TranscriptSegment(start: 20, end: 30, text: "Back to it.")
        ]
        let ad = AdSpan(start: 10, end: 20, kind: .hostRead, sponsor: nil)

        let excerpts = AdSkippingManager.adTranscripts(of: [ad], in: transcript)

        XCTAssertEqual(excerpts[ad]?.ad, "This episode is brought to you by Acme.")
        XCTAssertEqual(excerpts[ad]?.before, "The show.")
        XCTAssertEqual(excerpts[ad]?.after, "", "The next line's middle is too far after the ad")
    }

    func testGivesAnEmptyExcerptForAnAdWithNoWords() {
        let ad = AdSpan(start: 50, end: 70, kind: .inserted, sponsor: nil)

        let excerpts = AdSkippingManager.adTranscripts(of: [ad], in: [TranscriptSegment(start: 0, end: 41, text: "", words: words)])

        XCTAssertEqual(excerpts[ad], AdTranscriptExcerpt(before: "", ad: "", after: ""))
    }
}

final class AdSpanStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testPersistsAnalysesAcrossInstances() throws {
        let analysis = makeAnalysis(uuid: "episode-1")
        try AdSpanStore(directory: directory).save(analysis)

        let store = AdSpanStore(directory: directory)
        XCTAssertEqual(store.analysis(for: "episode-1"), analysis)
        XCTAssertNil(store.analysis(for: "episode-2"))
    }

    func testRemovesAnalyses() throws {
        let store = AdSpanStore(directory: directory)
        try store.save(makeAnalysis(uuid: "episode-1"))

        store.remove("episode-1")

        XCTAssertNil(store.analysis(for: "episode-1"))
        XCTAssertNil(AdSpanStore(directory: directory).analysis(for: "episode-1"))
    }

    func testIgnoresAnalysesFromOtherVersions() throws {
        let analysis = makeAnalysis(uuid: "episode-1", version: EpisodeAdAnalysis.currentVersion + 1)
        try AdSpanStore(directory: directory).save(analysis)

        XCTAssertNil(AdSpanStore(directory: directory).analysis(for: "episode-1"))
    }

    func testOnlyKeepsVersion2AnalysesFoundByOpenRouter() throws {
        let store = AdSpanStore(directory: directory)
        try store.save(makeAnalysis(uuid: "openrouter", version: 2, classifier: "openrouter:test/model"))
        try store.save(makeAnalysis(uuid: "on-device", version: 2, classifier: "on-device"))

        let reloaded = AdSpanStore(directory: directory)
        XCTAssertNotNil(reloaded.analysis(for: "openrouter"))
        XCTAssertNil(reloaded.analysis(for: "on-device"))
    }

    func testDeletesAnalysesOfEpisodesThatArentDownloaded() throws {
        let store = AdSpanStore(directory: directory)
        try store.save(makeAnalysis(uuid: "kept"))
        try store.save(makeAnalysis(uuid: "deleted"))
        _ = store.analysis(for: "deleted")

        store.removeAll(except: ["kept"])

        XCTAssertNotNil(store.analysis(for: "kept"))
        XCTAssertNil(store.analysis(for: "deleted"))
        XCTAssertNil(AdSpanStore(directory: directory).analysis(for: "deleted"))
    }

    func testLeavesTranscriptsAloneWhenDeletingAnalyses() throws {
        let transcripts = TranscriptStore(directory: directory.appendingPathComponent("Transcripts", isDirectory: true))
        try transcripts.save([TranscriptSegment(start: 0, end: 1, text: "Hi.")], for: "kept", audioFileSize: 1, audioDuration: 1)

        AdSpanStore(directory: directory).removeAll(except: [])

        XCTAssertNotNil(transcripts.transcript(for: "kept", audioFileSize: 1))
    }

    private func makeAnalysis(uuid: String, version: Int = EpisodeAdAnalysis.currentVersion, classifier: String = "test") -> EpisodeAdAnalysis {
        EpisodeAdAnalysis(version: version,
                          episodeUuid: uuid,
                          analyzedAt: Date(timeIntervalSinceReferenceDate: 1000),
                          classifier: classifier,
                          audioFileSize: 1234,
                          transcriptSegmentCount: 3,
                          spans: [AdSpan(start: 10, end: 40, kind: .inserted, sponsor: "Acme")])
    }
}

private final class OpenRouterURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let requestHandler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        do {
            let (response, data) = try requestHandler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private extension URLRequest {
    /// URLSession moves the body into a stream before it reaches a URLProtocol
    var bodyData: Data {
        if let httpBody {
            return httpBody
        }

        guard let stream = httpBodyStream else { return Data() }

        var data = Data()
        stream.open()
        defer { stream.close() }
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
