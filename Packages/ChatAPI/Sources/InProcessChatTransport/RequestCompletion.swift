import ChatAPI
import Foundation

/// Resolves the caller independently of an endpoint that ignores cancellation.
/// Its underlying work remains charged to the connection until it really ends.
actor RequestCompletion<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, any Error>?
    private var result: Result<Value, any Error>?
    private var operation: Task<Void, Never>?
    private var timeout: Task<Void, Never>?

    func run(
        deadline: Duration?,
        operation execute: @escaping @Sendable () async throws -> Value,
        discard: @escaping @Sendable (Value) async -> Void = { _ in },
        finished: @escaping @Sendable () async -> Void
    ) async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let result {
                    continuation.resume(with: result)
                    Task { await finished() }
                    return
                }
                self.continuation = continuation
                operation = Task {
                    let result: Result<Value, any Error>
                    do {
                        result = try await .success(execute())
                    } catch is CancellationError {
                        result = .failure(CancellationError())
                    } catch let failure as ServiceFailure {
                        result = .failure(failure)
                    } catch {
                        result = .failure(ServiceFailure.internalFailure)
                    }
                    let accepted = complete(result)
                    if !accepted, case let .success(value) = result {
                        await discard(value)
                    }
                    await finished()
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

    @discardableResult
    private func complete(_ result: Result<Value, any Error>) -> Bool {
        guard self.result == nil else { return false }
        self.result = result
        timeout?.cancel()
        timeout = nil
        if case .failure = result {
            operation?.cancel()
        }
        operation = nil
        continuation?.resume(with: result)
        continuation = nil
        return true
    }
}
