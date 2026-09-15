import Foundation

/// One immediate fetch, then every five seconds. Push delivery and token registration
/// are independent of this loop. The owner stops it when iOS backgrounds the app.
@MainActor
final class GenerationActivityPoller {
    private var task: Task<Void, Never>?
    private var jobID: String?
    private var generation = 0
    private let sleep: @MainActor (TimeInterval) async throws -> Void

    init(sleep: @escaping @MainActor (TimeInterval) async throws -> Void = {
        try await Task.sleep(for: .seconds($0))
    }) {
        self.sleep = sleep
    }

    func start(jobID: String, refresh: @escaping @MainActor () async throws -> Bool) {
        guard self.jobID != jobID || task == nil else { return }
        stop()
        self.jobID = jobID
        let generation = self.generation
        task = Task { [weak self, sleep] in
            defer {
                if self?.generation == generation { self?.task = nil }
            }
            var retryDelay: TimeInterval = 5
            while !Task.isCancelled {
                var delay: TimeInterval = 5
                do {
                    guard try await refresh() else { return }
                    retryDelay = 5
                } catch {
                    if Task.isCancelled { return }
                    delay = retryDelay
                    retryDelay = min(retryDelay * 2, 30)
                }
                do {
                    try Task.checkCancellation()
                    try await sleep(delay)
                } catch { return }
            }
        }
    }

    func stop() {
        generation &+= 1
        task?.cancel()
        task = nil
        jobID = nil
    }
}
