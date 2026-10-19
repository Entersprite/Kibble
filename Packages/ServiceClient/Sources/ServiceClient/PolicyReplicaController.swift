import ChatAPI
import Foundation

/// One account's owned reconciliation loop. Requests always retain its binding;
/// an old replica can never follow a replacement login implicitly.
public actor PolicyReplicaController {
    public nonisolated let cache: PolicyReplicaCache
    private let client: AccountClient
    private var task: Task<Void, Never>?
    private var stopped = false

    public init(client: AccountClient, cache: PolicyReplicaCache) {
        self.client = client; self.cache = cache
    }

    public func start() {
        guard task == nil, !stopped else { return }
        task = Task { [weak self, cache] in
            for await _ in cache.snapshots() {
                guard !Task.isCancelled else { return }
                await self?.reconcile()
            }
        }
    }

    public func stop() async {
        stopped = true
        cache.close()
        let task = task
        self.task = nil
        task?.cancel()
        await task?.value
    }

    private func reconcile() async {
        var failures = 0
        while !stopped, !Task.isCancelled, cache.work.needed {
            let invalidation = cache.work.invalidation
            do {
                let policy = try await call(GetAccountPolicy())
                try Task.checkCancellation()
                try cache.accept(policy, invalidation: invalidation)
                if let request = try cache.writeRequest() {
                    let acknowledgement = try await call(request)
                    try Task.checkCancellation()
                    try cache.accept(acknowledgement, invalidation: invalidation)
                }
                failures = 0
            } catch is CancellationError {
                return
            } catch {
                guard !stopped, !Task.isCancelled else { return }
                cache.failed()
                failures = min(failures + 1, 5)
                // Conflicts and unknown replies both re-read before rebasing. No
                // failed full-document write is blindly replayed.
                do {
                    try await Task.sleep(for: .milliseconds(200 * (1 << failures)))
                } catch {
                    return
                }
            }
        }
    }

    private func call<Request: ServiceRequestPayload>(_ request: Request) async throws -> Request.Response {
        try await client.call(
            request,
            account: cache.binding.account,
            revision: cache.binding.revision,
            timeout: 10
        )
    }
}
