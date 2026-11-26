import Foundation
import Synchronization

/// Fresh bounded response streams let a restarted service host reconnect to
/// the same process-level notification delegate. Launching clicks are retained.
public final class AccountNotificationResponses: Sendable {
    private struct State {
        var observers: [UUID: AsyncStream<AccountNotificationResponse>.Continuation] = [:]
        var pending: [AccountNotificationResponse] = []
    }

    private let state = Mutex(State())
    private let publication = Mutex(())

    public init() {}

    public func stream() -> AsyncStream<AccountNotificationResponse> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<AccountNotificationResponse>
            .makeStream(bufferingPolicy: .bufferingNewest(64))
        state.withLock {
            $0.observers[id] = continuation
            for response in $0.pending {
                continuation.yield(response)
            }
            $0.pending = []
        }
        continuation.onTermination = { [weak self] _ in self?.remove(id) }
        return stream
    }

    public func send(_ response: AccountNotificationResponse) {
        publication.withLock { _ in
            let observers = state.withLock { state in
                if state.observers.isEmpty {
                    if state.pending.count == 64 {
                        state.pending.removeFirst()
                    }
                    state.pending.append(response)
                }
                return Array(state.observers.values)
            }
            for observer in observers {
                observer.yield(response)
            }
        }
    }

    private func remove(_ id: UUID) {
        state.withLock { $0.observers[id] = nil }
    }
}
