import Foundation
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
        let body: [String: Any] = [
            "choices": [
                ["message": ["role": "assistant", "content": String(decoding: output, as: UTF8.self)], "finish_reason": "stop"]
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
