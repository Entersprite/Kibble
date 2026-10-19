import ChatAPI
import Foundation

/// Resolves the caller independently of an endpoint that ignores cancellation.
/// Its underlying work remains charged to the connection until it really ends.
actor RequestCompletion {
    private var continuation: CheckedContinuation<Data, any Error>?
    private var result: Result<Data, any Error>?
    private var operation: Task<Void, Never>?
    private var timeout: Task<Void, Never>?

    func run(
        deadline: Duration?,
        operation execute: @escaping @Sendable () async throws -> Data,
        finished: @escaping @Sendable () async -> Void
    ) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let result {
                    continuation.resume(with: result)
                    Task { await finished() }
                    return
                }
                self.continuation = continuation
                operation = Task {
                    let result: Result<Data, any Error>
                    do {
                        result = try await .success(execute())
                    } catch is CancellationError {
                        result = .failure(CancellationError())
                    } catch let failure as ServiceFailure {
                        result = .failure(failure)
                    } catch {
                        result = .failure(ServiceFailure.internalFailure)
                    }
                    await finished()
                    complete(result)
                }
                if let deadline {
                    timeout = Task {
                        do {
                            try await Task.sleep(for: deadline)
                        } catch {
                            return
                        }
                        complete(.failure(ServiceFailure.deadlineExceeded))
                    }
                }
            }
        } onCancel: {
            Task { await self.complete(.failure(CancellationError())) }
        }
    }

    private func complete(_ result: Result<Data, any Error>) {
        guard self.result == nil else { return }
        self.result = result
        timeout?.cancel()
        timeout = nil
        if case .failure = result {
            operation?.cancel()
        }
        operation = nil
        continuation?.resume(with: result)
        continuation = nil
    }
}
