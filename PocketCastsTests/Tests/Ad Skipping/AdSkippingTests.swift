import Foundation
import XCTest
@testable import podcasts

final class ClaudeAdClassifierTests: XCTestCase {
    private let transcript = [
        TranscriptSegment(start: 0, end: 4.5, text: "Welcome back to the show."),
        TranscriptSegment(start: 4.5, end: 30, text: "This episode is brought to you by Acme."),
        TranscriptSegment(start: 30, end: 40, text: "Now, where were we?")
    ]

    private let context = AdClassificationContext(podcastTitle: "The Show", episodeTitle: "Episode 1", duration: 100)

    override func tearDown() {
        ClaudeURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testSendsTranscriptToClaudeAndParsesSpans() async throws {
        var receivedRequest: URLRequest?
        var receivedBody: [String: Any]?
        ClaudeURLProtocol.requestHandler = { request in
            receivedRequest = request
            receivedBody = try JSONSerialization.jsonObject(with: request.bodyData) as? [String: Any]
            return Self.success(ads: [
                ["start": 4.5, "end": 30, "kind": "host_read", "sponsor": "Acme"]
            ])
        }

        let spans = try await makeClassifier().adSpans(in: transcript, context: context)

        XCTAssertEqual(spans, [AdSpan(start: 4.5, end: 30, kind: .hostRead, sponsor: "Acme")])

        let request = try XCTUnwrap(receivedRequest)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "server-side-fallback-2026-07-01")

        let body = try XCTUnwrap(receivedBody)
        XCTAssertEqual(body["model"] as? String, ClaudeAdClassifier.model)
        XCTAssertEqual(body["fallbacks"] as? String, "default")
        let outputConfig = try XCTUnwrap(body["output_config"] as? [String: Any])
        XCTAssertEqual((outputConfig["format"] as? [String: Any])?["type"] as? String, "json_schema")

        let message = try XCTUnwrap((body["messages"] as? [[String: Any]])?.first?["content"] as? String)
        XCTAssertTrue(message.contains("Podcast: The Show"))
        XCTAssertTrue(message.contains("[4.5-30.0] This episode is brought to you by Acme."))
    }

    func testCleansUpSpans() async throws {
        ClaudeURLProtocol.requestHandler = { _ in
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

    func testRetriesWithoutFallbacksWhenTheRequestIsRejected() async throws {
        var requests: [URLRequest] = []
        ClaudeURLProtocol.requestHandler = { request in
            requests.append(request)
            if requests.count == 1 {
                let body = #"{"type":"error","error":{"type":"invalid_request_error","message":"fallbacks: unsupported"}}"#
                return (HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
            }
            return Self.success(ads: [])
        }

        let spans = try await makeClassifier().adSpans(in: transcript, context: context)

        XCTAssertEqual(spans, [])
        XCTAssertEqual(requests.count, 2)
        XCTAssertNil(requests.last?.value(forHTTPHeaderField: "anthropic-beta"))
        let retryBody = try JSONSerialization.jsonObject(with: try XCTUnwrap(requests.last).bodyData) as? [String: Any]
        XCTAssertNil(retryBody?["fallbacks"])
    }

    func testThrowsOnRefusal() async {
        ClaudeURLProtocol.requestHandler = { request in
            let body = #"{"content":[],"stop_reason":"refusal"}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }

        do {
            _ = try await makeClassifier().adSpans(in: transcript, context: context)
            XCTFail("Expected the refusal to throw")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Claude declined to classify this episode")
        }
    }

    // MARK: - Helpers

    private func makeClassifier() -> ClaudeAdClassifier {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClaudeURLProtocol.self]
        return ClaudeAdClassifier(apiKey: "test-key", session: URLSession(configuration: configuration))
    }

    private static func success(ads: [[String: Any]]) -> (HTTPURLResponse, Data) {
        let output = try! JSONSerialization.data(withJSONObject: ["ads": ads])
        let body: [String: Any] = [
            "content": [
                ["type": "thinking", "thinking": ""],
                ["type": "text", "text": String(decoding: output, as: UTF8.self)]
            ],
            "stop_reason": "end_turn"
        ]
        let response = HTTPURLResponse(url: URL(string: "https://api.anthropic.com/v1/messages")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (response, try! JSONSerialization.data(withJSONObject: body))
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
        XCTAssertEqual(store.allAnalyses(), [analysis])
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

private final class ClaudeURLProtocol: URLProtocol {
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
