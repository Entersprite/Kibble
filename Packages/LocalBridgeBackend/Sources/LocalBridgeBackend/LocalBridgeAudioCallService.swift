import ChatKit
import Foundation

/// App-session call adapter. Provider handles and protocol state stay behind
/// the domain seam; the host supplies the platform's audio engine.
@MainActor
public final class LocalBridgeAudioCallService: AudioCallQuiescing {
    public let events: AsyncStream<AudioCallEvent>
    let continuation: AsyncStream<AudioCallEvent>.Continuation
    let trial: MeetDMCallTrial
    let mediaFactory: @MainActor @Sendable () -> any CallMediaEngine
    var people: [UUID: MeetDMCallPerson] = [:]
    var incoming: MeetIncomingDMCalls?
    var snapshot: AudioCallSnapshot?
    var incomingHandle: UUID?
    var media: (any CallMediaEngine)?
    var loading: Task<Void, any Error>?
    var listening: Task<Void, Never>?
    var operation: Task<Void, any Error>?
    var stopping: Task<Void, Never>?
    var sessionScope = UUID()
    var callScope = UUID()
    var muteSequence: UInt64 = 0
    var isStopping = false
    var directoryRecipients: [AudioCallRecipient]?
    var directoryRevision = 0
    var hasLoadedPeople = false
    var retrySleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    public init(
        trial: MeetDMCallTrial,
        mediaFactory: @escaping @MainActor @Sendable () -> any CallMediaEngine
    ) {
        self.trial = trial
        self.mediaFactory = mediaFactory
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
    }

    public convenience init(
        store: KeychainCredentialStore,
        expectedSession: StoredSessionSummary,
        mediaFactory: @escaping @MainActor @Sendable () -> any CallMediaEngine
    ) {
        self.init(
            trial: MeetDMCallTrial(store: store, expectedSession: expectedSession),
            mediaFactory: mediaFactory
        )
    }

    /// Private, redacted diagnostic text for owner-operated smoke tests.
    public var report: String {
        get async {
            let native = await trial.report
            let watch = await incoming?.report ?? ""
            return native + "\n" + watch
        }
    }

    public func startListening() async throws {
        guard !isStopping else { throw CancellationError() }
        if let loading {
            try await loading.value
            return
        }
        guard listening == nil else { return }
        let scope = sessionScope
        let task = Task { try await self.loadAndListenWithRetry(scope: scope) }
        loading = task
        defer {
            if sessionScope == scope {
                loading = nil
            }
        }
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch {
            guard sessionScope == scope, !Task.isCancelled else { throw CancellationError() }
            throw ChatError.transport("Incoming calls could not connect.")
        }
    }

    func loadAndListen(scope: UUID) async throws {
        if !hasLoadedPeople {
            try await loadCallDirectory(scope: scope)
        }
        let watcher = try await trial.incomingCalls()
        try checkSession(scope)
        incoming = watcher
        // A directory delivery can arrive while the watcher bootstraps.
        await watcher.updatePeople(trial.incomingPeople())
        try checkSession(scope)
        listening = Task { [weak self] in
            while !Task.isCancelled {
                await watcher.run { [weak self] event in
                    await self?.receiveIncoming(event, scope: scope)
                }
                guard let self, sessionScope == scope, !Task.isCancelled else { return }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }

    public func beginStopping() {
        guard !isStopping else { return }
        sessionScope = UUID(); callScope = UUID()
        isStopping = true
        // Cancel before yielding to teardown: a late bootstrap response must
        // not begin another request once stop has been requested.
        loading?.cancel()
        operation?.cancel()
        listening?.cancel()
        media?.setMuted(true)
    }

    public func stop() async {
        if let stopping {
            await stopping.value; return
        }
        beginStopping()
        let task = Task { await self.performStop() }
        stopping = task
        await task.value
        stopping = nil
        isStopping = false
    }

    public func pauseForRecovery(barrier: UUID) async throws {
        await stop()
        continuation.yield(.listenerBarrier(barrier))
    }

    func performStop() async {
        sessionScope = UUID()
        callScope = UUID()
        let loading = loading
        let operation = operation
        let listening = listening
        loading?.cancel()
        operation?.cancel()
        listening?.cancel()
        media?.setMuted(true)
        await incoming?.stop()
        await trial.close()
        _ = await loading?.result
        _ = await operation?.result
        _ = await listening?.result
        self.loading = nil
        self.operation = nil
        self.listening = nil
        incoming = nil
        media = nil
        people = [:]
        hasLoadedPeople = false
        directoryRecipients = nil
        incomingHandle = nil
        if let snapshot {
            publish(phase: .ended, snapshot: snapshot)
        }
        snapshot = nil
        continuation.yield(.recipientsChanged([]))
    }

    func checkSession(_ scope: UUID) throws {
        try Task.checkCancellation()
        guard sessionScope == scope, !isStopping else { throw CancellationError() }
    }

    func checkCall(_ id: UUID, scope: UUID) throws {
        try Task.checkCancellation()
        guard snapshot?.id == id, callScope == scope, !isStopping else { throw CancellationError() }
    }

    static func recipient(_ person: MeetDMCallPerson) -> AudioCallRecipient {
        AudioCallRecipient(
            conversationID: person.conversationID, memberID: person.memberID, displayName: person.name
        )
    }

    func publish(
        phase: AudioCallPhase, snapshot previous: AudioCallSnapshot, failure: String? = nil,
        endReason: AudioCallEndReason? = nil
    ) {
        let next = AudioCallSnapshot(
            id: previous.id, recipient: previous.recipient, direction: previous.direction,
            phase: phase, isMuted: previous.isMuted, failureMessage: failure, endReason: endReason
        )
        snapshot = next
        continuation.yield(.snapshot(next))
    }

    var hasCall: Bool {
        guard let snapshot else { return false }
        switch snapshot.phase {
        case .ended, .failed, .declined: return false
        default: return true
        }
    }
}
