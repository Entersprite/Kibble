import ChatAPI
import ChatKit
import Foundation
import Synchronization

public struct PolicyReplicaSnapshot: Sendable {
    public let sequence: UInt64
    public let settings: NotificationSettings
    public let isReady: Bool
    public let canEdit: Bool
    public let error: String?
}

/// Synchronous presentation adapter over a durable outbox. Fresh validation is
/// intentionally process-local; a cached acknowledgement alone grants no privacy permission.
public final class PolicyReplicaCache: Sendable {
    struct State {
        var document: PolicyReplicaDocument
        var validated = false
        var controlAvailable = true
        var closed = false
        var error: String?
        var sequence: UInt64 = 0
        var invalidation: UInt64 = 0
        var metadataRevision: String?
        var observers: [UUID: AsyncStream<PolicyReplicaSnapshot>.Continuation] = [:]
    }

    let state: Mutex<State>
    private let publication = Mutex(())
    let storage: any PolicyReplicaStorage
    public let binding: PolicyReplicaBinding
    public let deviceID: String

    public init(binding: PolicyReplicaBinding, deviceID: String, storage: any PolicyReplicaStorage) throws {
        self.binding = binding; self.deviceID = deviceID; self.storage = storage
        let document = try storage.load() ?? PolicyReplicaDocument(binding: binding)
        try document.validate(for: binding)
        state = Mutex(State(document: document))
    }

    public var snapshot: PolicyReplicaSnapshot {
        state.withLock { Self.snapshot($0) }
    }

    public var isReady: Bool {
        state.withLock { Self.isReady($0) }
    }

    public func snapshots() -> AsyncStream<PolicyReplicaSnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<PolicyReplicaSnapshot>
            .makeStream(bufferingPolicy: .bufferingNewest(1))
        state.withLock {
            if $0.closed {
                continuation.finish()
            } else {
                $0.observers[id] = continuation
                continuation.yield(Self.snapshot($0))
            }
        }
        continuation.onTermination = { [weak self] _ in self?.removeObserver(id) }
        return stream
    }

    public func save(_ settings: NotificationSettings) throws {
        var persistenceFailure: (any Error)?
        do {
            try mutate { state in
                guard !state.closed,
                      state.document.acknowledged != nil else { throw ServiceFailure.policyUnavailable }
                try state.document.update(with: settings)
                do {
                    try storage.save(state.document)
                    state.error = nil
                } catch {
                    // Retain the user's intent in memory for retry. Re-reading
                    // a permissive server value must not undo a refused save.
                    persistenceFailure = error
                    state.validated = false
                    state.error = Self.pendingError
                }
            }
        } catch {
            failed()
            throw error
        }
        if let persistenceFailure {
            throw persistenceFailure
        }
    }

    public func invalidate(revision: String?) {
        guard state.withLock({ !$0.closed && revision != $0.metadataRevision }) else { return }
        mutate { state in
            guard !state.closed, revision != state.metadataRevision else { return }
            state.metadataRevision = revision
            guard revision != state.document.acknowledged?.revision else { return }
            state.invalidation += 1
            state.validated = false
        }
    }

    public func setControlAvailable(_ available: Bool) {
        guard state.withLock({ !$0.closed && available != $0.controlAvailable }) else { return }
        mutate {
            guard !$0.closed, available != $0.controlAvailable else { return }
            $0.controlAvailable = available
            $0.invalidation += 1
            $0.validated = false
        }
    }

    public func close() {
        let observers = state.withLock { state in
            state.closed = true; state.validated = false
            let observers = Array(state.observers.values)
            state.observers = [:]
            return observers
        }
        for observer in observers {
            observer.finish()
        }
    }

    var work: (needed: Bool, invalidation: UInt64) {
        state.withLock { (!$0.closed && (!$0.validated || !$0.document.pending.isEmpty), $0.invalidation) }
    }

    func accept(_ policy: AccountPolicy, invalidation: UInt64) throws {
        try mutate { state in
            guard !state.closed else { throw CancellationError() }
            try PolicyReplicaDocument.validate(policy.settings)
            var document = state.document
            document.acknowledged = policy
            document.pending = try document.pending.filter { try !$0.isFulfilled(by: policy.settings) }
            try document.validate(for: binding)
            try storage.save(document)
            state.document = document
            state.validated = invalidation == state.invalidation || policy.revision == state.metadataRevision
            state.error = nil
        }
    }

    func writeRequest() throws -> SetAccountPolicy? {
        try state.withLock { state in
            guard !state.closed else { throw CancellationError() }
            guard let policy = state.document.acknowledged,
                  !state.document.pending.isEmpty else { return nil }
            return try SetAccountPolicy(
                settings: state.document.effectiveSettings(),
                expectedRevision: policy.revision
            )
        }
    }

    func failed() {
        mutate {
            guard !$0.closed else { return }
            $0.validated = false
            $0.error = Self.pendingError
        }
    }

    private func removeObserver(_ id: UUID) {
        state.withLock { $0.observers[id] = nil }
    }

    func mutate(_ body: (inout State) throws -> Void) rethrows {
        try publication.withLock { _ in
            let publication = try state.withLock { state in
                var candidate = state
                try body(&candidate)
                candidate.sequence += 1
                state = candidate
                return (Self.snapshot(state), Array(state.observers.values))
            }
            for observer in publication.1 {
                observer.yield(publication.0)
            }
        }
    }

    private static let pendingError =
        "Notification settings are waiting to sync. Notifications, read receipts and typing are paused."

    private static func snapshot(_ state: State) -> PolicyReplicaSnapshot {
        PolicyReplicaSnapshot(
            sequence: state.sequence,
            settings: (try? state.document.effectiveSettings()) ?? NotificationSettings(),
            isReady: isReady(state),
            canEdit: !state.closed && state.document.acknowledged != nil,
            error: state.error
        )
    }

    private static func isReady(_ state: State) -> Bool {
        !state.closed && state.controlAvailable && state.validated && state.document.pending.isEmpty
    }
}
