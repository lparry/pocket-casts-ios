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

    func testAsksForTheExactBoundaryWord() async throws {
        var receivedBody: [String: Any]?
        OpenRouterURLProtocol.requestHandler = { request in
            receivedBody = try JSONSerialization.jsonObject(with: request.bodyData) as? [String: Any]
            return Self.success(content: #"{"word_index": 1}"#)
        }
        let request = AdBoundaryRequest(edge: .start,
                                        ad: AdSpan(start: 79.3, end: 107.7, kind: .inserted, sponsor: "Bank"),
                                        words: [TimedWord(start: 76.3, end: 77, text: "courtroom."), TimedWord(start: 79.32, end: 79.62, text: "Your")],
                                        context: context)

        let index = try await makeClassifier().boundaryWordIndex(for: request)

        XCTAssertEqual(index, 1)
        let prompt = try XCTUnwrap((receivedBody?["messages"] as? [[String: Any]])?.last?["content"] as? String)
        XCTAssertTrue(prompt.contains("Which word starts this ad?"))
        XCTAssertTrue(prompt.contains("1 [79.32] Your"))
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

    func testMovesEdgesOntoTheChosenWords() async {
        // Picks the word 3 before each edge's window midpoint for the start, and the one 2 after for the end
        let classifier = FakeClassifier { request in
            let middle = request.words.firstIndex { $0.start >= (request.edge == .start ? request.ad.start : request.ad.end) } ?? 0
            return request.edge == .start ? middle - 3 : middle + 2
        }

        let refined = await AdBoundaryRefiner(classifier: classifier).refine([AdSpan(start: 20, end: 40, kind: .inserted, sponsor: nil)], words: words, context: context)

        XCTAssertEqual(refined, [AdSpan(start: 17, end: 42.8, kind: .inserted, sponsor: nil)])
    }

    func testKeepsEdgesTheClassifierCantPlace() async {
        let span = AdSpan(start: 20, end: 40, kind: .inserted, sponsor: nil)

        let notFound = await AdBoundaryRefiner(classifier: FakeClassifier { _ in nil }).refine([span], words: words, context: context)
        let outOfRange = await AdBoundaryRefiner(classifier: FakeClassifier { _ in 500 }).refine([span], words: words, context: context)
        let failing = await AdBoundaryRefiner(classifier: FakeClassifier { _ in throw URLError(.timedOut) }).refine([span], words: words, context: context)

        XCTAssertEqual(notFound, [span])
        XCTAssertEqual(outOfRange, [span])
        XCTAssertEqual(failing, [span])
    }

    private struct FakeClassifier: AdClassifier {
        let boundary: (AdBoundaryRequest) throws -> Int?

        var identifier: String {
            "fake"
        }

        func adSpans(in transcript: [TranscriptSegment], context: AdClassificationContext) async throws -> [AdSpan] {
            []
        }

        func boundaryWordIndex(for request: AdBoundaryRequest) async throws -> Int? {
            try boundary(request)
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

    private func makeAnalysis(uuid: String, version: Int = EpisodeAdAnalysis.currentVersion) -> EpisodeAdAnalysis {
        EpisodeAdAnalysis(version: version,
                          episodeUuid: uuid,
                          analyzedAt: Date(timeIntervalSinceReferenceDate: 1000),
                          classifier: "test",
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
