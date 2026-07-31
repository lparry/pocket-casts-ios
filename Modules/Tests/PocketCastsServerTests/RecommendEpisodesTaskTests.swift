import XCTest
@testable import PocketCastsServer

final class RecommendEpisodesTaskTests: XCTestCase {
    func testConfiguredRequestTimeoutIsAppliedToNetworkRequest() {
        let task = RecommendEpisodesTask(requestTimeout: 12)

        let request = task.createRequest(url: URL(string: "https://example.com")!, method: "POST", token: nil)

        XCTAssertEqual(request.timeoutInterval, 12)
    }

    func testCancellationBeforeTaskInstallationIsDelivered() {
        let cancellation = RecommendationCancellation()
        cancellation.cancel()
        let task = RecommendEpisodesTask()
        var completions = 0
        task.completion = { episode in
            XCTAssertNil(episode)
            completions += 1
        }
        cancellation.install(task)
        task.apiTokenAcquisitionFailed()
        XCTAssertTrue(task.isCancelled)
        XCTAssertEqual(completions, 1)
    }

    func testCancellationAfterTaskInstallationIsDelivered() {
        let cancellation = RecommendationCancellation()
        let task = RecommendEpisodesTask()
        var completions = 0
        task.completion = { episode in
            XCTAssertNil(episode)
            completions += 1
        }
        cancellation.install(task)
        cancellation.cancel()
        cancellation.cancel()
        XCTAssertTrue(task.isCancelled)
        XCTAssertEqual(completions, 1)
    }

    func testTokenAcquisitionFailureCompletesWithNil() {
        let task = RecommendEpisodesTask()
        let completion = expectation(description: "Recommendation completes")

        task.completion = { episode in
            XCTAssertNil(episode)
            completion.fulfill()
        }

        task.apiTokenAcquisitionFailed()

        wait(for: [completion], timeout: 1)
    }

    func testCancellationCompletesOnlyOnce() {
        let task = RecommendEpisodesTask()
        let completion = expectation(description: "Recommendation completes once")
        completion.expectedFulfillmentCount = 1
        completion.assertForOverFulfill = true

        task.completion = { episode in
            XCTAssertNil(episode)
            completion.fulfill()
        }

        task.cancel()
        task.apiTokenAcquisitionFailed()

        wait(for: [completion], timeout: 1)
    }
}
