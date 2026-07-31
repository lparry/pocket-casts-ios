import Foundation
import PocketCastsDataModel
import PocketCastsUtils
import SwiftProtobuf

class RecommendEpisodesTask: ApiBaseTask, @unchecked Sendable {
    static let defaultRequestTimeout: TimeInterval = 60

    var completion: ((Episode?) -> Void)?
    private let completionLock = NSLock()
    private var hasCompleted = false
    private let requestTimeout: TimeInterval

    init(requestTimeout: TimeInterval = defaultRequestTimeout) {
        self.requestTimeout = max(requestTimeout, 0.001)
        super.init()
    }

    override func createRequest(url: URL, method: String, token: String?) -> URLRequest {
        var request = super.createRequest(url: url, method: method, token: token)
        request.timeoutInterval = requestTimeout
        return request
    }

    override func cancel() {
        super.cancel()
        complete(with: nil)
    }

    override func apiTokenAcquisitionFailed() {
        complete(with: nil)
    }

    override func apiTokenAcquired(token: String) {
        guard !isCancelled else {
            complete(with: nil)
            return
        }

        let url = ServerConstants.Urls.api() + "discover/recommend_episodes"

        do {
            let request = Api_BasicRequest()
            let data = try request.serializedData()

            let (response, httpStatus) = postToServer(url: url, token: token, data: data)

            guard let responseData = response, httpStatus == ServerConstants.HttpConstants.ok else {
                complete(with: nil)

                return
            }

            do {
                if let topEpisode = try Api_EpisodesResponse(serializedBytes: responseData).episodes.first {
                    let episode = Episode()
                    episode.uuid = topEpisode.uuid
                    episode.podcastUuid = topEpisode.podcastUuid
                    complete(with: episode)
                } else {
                    complete(with: nil)
                }
            } catch {
                FileLog.shared.addMessage("Decoding recommended episodes failed \(error.localizedDescription)")
                complete(with: nil)
            }
        } catch {
            FileLog.shared.addMessage("Recommended episodes failed \(error.localizedDescription)")
            complete(with: nil)
        }
    }

    private func complete(with episode: Episode?) {
        completionLock.lock()
        guard !hasCompleted else {
            completionLock.unlock()
            return
        }

        hasCompleted = true
        let completion = completion
        self.completion = nil
        completionLock.unlock()
        completion?(episode)
    }
}
