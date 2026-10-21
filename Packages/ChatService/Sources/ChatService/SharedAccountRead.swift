import ChatAPI
import Foundation

/// The account owns the worker; cancellation removes just the caller's waiter.
final class SharedAccountRead<Value: Sendable>: Sendable {
    let id: UUID
    let worker: Task<Void, Never>
    private let completion: AccountReadCompletion<Value>

    init(id: UUID, operation: @escaping @Sendable () async throws -> Value) {
        self.id = id
        let completion = AccountReadCompletion<Value>()
        self.completion = completion
        worker = Task {
            let result: Result<Value, any Error>
            do { result = try await .success(operation()) } catch { result = .failure(error) }
            await completion.finish(result)
        }
    }

    func value() async throws -> Value {
        try await completion.value()
    }

    var waitingCount: Int {
        get async { await completion.waitingCount }
    }
}

private actor AccountReadCompletion<Value: Sendable> {
    private var result: Result<Value, any Error>?
    private var waiters: [UUID: CheckedContinuation<Value, any Error>] = [:]

    var waitingCount: Int {
        waiters.count
    }

    func finish(_ result: Result<Value, any Error>) {
        self.result = result
        let pending = waiters.values
        waiters = [:]
        for waiter in pending {
            waiter.resume(with: result)
        }
    }

    func value() async throws -> Value {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if let result {
                return try result.get()
            }
            guard waiters.count < 64 else { throw ServiceFailure.overloaded }
            return try await withCheckedThrowingContinuation { waiters[id] = $0 }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}
