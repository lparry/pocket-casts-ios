import Foundation
import PocketCastsDataModel

public class RecommendationHelper {
    public init() {}

    @discardableResult
    public func recommendEpisode(
        timeout: TimeInterval? = nil,
        completion: @escaping ((Episode?) -> Void)
    ) -> Operation? {
        if !SyncManager.isUserLoggedIn() {
            completion(nil)

            return nil
        }

        let recommendTask = RecommendEpisodesTask(requestTimeout: timeout ?? RecommendEpisodesTask.defaultRequestTimeout)
        let timeoutWork = timeout.map { _ in
            DispatchWorkItem {
                recommendTask.cancel()
            }
        }
        recommendTask.completion = { episode in
            timeoutWork?.cancel()
            completion(episode)
        }
        if let timeout, let timeoutWork {
            DispatchQueue.global().asyncAfter(deadline: .now() + max(0, timeout), execute: timeoutWork)
        }
        DispatchQueue.global().async {
            guard !recommendTask.isCancelled else { return }
            recommendTask.runTaskSynchronously()
        }
        return recommendTask
    }

    public func recommendEpisodeAsync(timeout: TimeInterval? = nil) async -> Episode? {
        let cancellation = RecommendationCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                let task = recommendEpisode(timeout: timeout) { continuation.resume(returning: $0) }
                cancellation.install(task)
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    public func recommendEpisode() -> Episode? {
        if !SyncManager.isUserLoggedIn() {
            return nil
        }

        let recommendTask = RecommendEpisodesTask()
        var episode: Episode?
        recommendTask.completion = { recommendedEpisode in
            episode = recommendedEpisode
        }
        recommendTask.runTaskSynchronously()

        return episode
    }
}

/// Handles cancellation racing with construction of the callback-based API task.
final class RecommendationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Operation?
    private var cancelled = false

    func install(_ task: Operation?) {
        lock.lock()
        let shouldCancel = cancelled
        if !shouldCancel { self.task = task }
        lock.unlock()
        if shouldCancel { task?.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = task
        self.task = nil
        lock.unlock()
        task?.cancel()
    }
}
