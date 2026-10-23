import ChatAPI
import ChatKit
import Foundation

/// A device-scoped API facade. Stopping this observer does not stop service media.
@MainActor
public final class ServiceAudioCallService: ExistingAudioCallService, ConversationAudioCallService {
    public let events: AsyncStream<AudioCallEvent>
    private let sink: AsyncStream<AudioCallEvent>.Continuation
    private let client: AccountClient
    private let account: ConnectedAccountID
    private let revision: ServiceAccountRevision
    private var generation = UUID()
    private var sourceID: UUID?
    private var observer: Task<Void, Never>?
    private var projection = ServiceCallStateProjection()

    public init(account: AccountSummary, client: AccountClient) throws {
        guard let revision = account.revision else { throw ServiceFailure.staleAccount }
        self.account = account.id; self.revision = revision; self.client = client
        (events, sink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
    }

    public func startListening() async throws {
        let epoch = generation
        do {
            let initial = try await read(after: nil, wait: 0)
            try check(epoch)
            try receive(initial)
        } catch {
            try check(epoch)
            reportConnectionFailure()
        }
        guard observer == nil else { return }
        observer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, generation == epoch else { return }
                do {
                    if projection.isConnectionUnavailable {
                        try await Task.sleep(for: .seconds(1))
                        try check(epoch)
                    }
                    let next = try await read(
                        after: projection.version, wait: projection.isConnectionUnavailable ? 0 : 20000
                    )
                    try check(epoch)
                    try receive(next)
                } catch {
                    guard !Task.isCancelled, generation == epoch else { return }
                    reportConnectionFailure()
                }
            }
        }
    }

    /// Provider-verified recipients arrive from the service; client hints grant nothing.
    public func updateRecipients(_: [AudioCallRecipient]) async {}

    public func startOutgoing(to recipient: AudioCallRecipient, callID: UUID) async throws {
        try await control(.init(action: "start", callID: callID, recipient: recipient))
    }

    public var canJoinExistingCalls: Bool {
        !projection.isConnectionUnavailable && projection.currentState?.supportsExistingJoin == true
    }

    public func joinExisting(to recipient: AudioCallRecipient, callID: UUID) async throws {
        try await control(.init(action: "join", callID: callID, recipient: recipient))
    }

    public var canCallConversations: Bool {
        !projection.isConnectionUnavailable && projection.currentState?.supportsConversationCalls == true
    }

    public func startConversationCall(to target: ConversationCallTarget, callID: UUID) async throws {
        try await controlConversation("start", target: target, id: callID)
    }

    public func joinConversationCall(to target: ConversationCallTarget, callID: UUID) async throws {
        try await controlConversation("join", target: target, id: callID)
    }

    private func controlConversation(
        _ action: String,
        target: ConversationCallTarget,
        id: UUID
    ) async throws {
        let epoch = generation
        if sourceID == nil {
            try await receive(read(after: nil, wait: 0))
        }
        try check(epoch)
        guard let sourceID else { throw ServiceFailure.staleCallSource }
        let request = ControlConversationCall(
            action: action, conversationID: target.conversationID, callID: id, sourceID: sourceID
        )
        let result = try await client.call(request, account: account, revision: revision)
        try check(epoch)
        try receive(result)
    }

    public func accept(callID: UUID) async throws {
        try await control(.init(action: "accept", callID: callID))
    }

    public func decline(callID: UUID) async throws {
        try await control(.init(action: "decline", callID: callID))
    }

    public func hangUp(callID: UUID) async throws {
        try await control(.init(action: "hangUp", callID: callID))
    }

    public func setMuted(_ muted: Bool, callID: UUID) async throws {
        try await control(.init(action: "mute", callID: callID, muted: muted))
    }

    /// Explicit native authentication recovery, permitted only while idle.
    public func restartListener() async throws {
        try await control(.init(action: "restart"))
    }

    public func prepareRecovery() async throws {
        await stop()
        try await control(.init(action: "pause"))
    }

    public func finishRecovery() async throws {
        try await restartListener()
    }

    public func stop() async {
        generation = UUID()
        let pending = observer
        observer = nil
        pending?.cancel()
        await pending?.value
        projection = ServiceCallStateProjection()
        sourceID = nil
    }

    private func read(after version: String?, wait: Int) async throws -> ServiceCallState {
        try await client.call(
            ReadCallState(after: version, waitMilliseconds: wait), account: account, revision: revision,
            timeout: 25
        )
    }

    private func control(_ request: ControlCall) async throws {
        let epoch = generation
        if sourceID == nil {
            try await receive(read(after: nil, wait: 0))
        }
        try check(epoch)
        let scoped = ControlCall(
            action: request.action,
            callID: request.callID,
            recipient: request.recipient,
            muted: request.muted,
            sourceID: sourceID
        )
        let result = try await client.call(scoped, account: account, revision: revision)
        try check(epoch)
        try receive(result)
    }

    private func receive(_ state: ServiceCallState) throws {
        let events = try projection.accept(state)
        sourceID = projection.currentState?.sourceID
        for event in events {
            sink.yield(event)
        }
    }

    private func reportConnectionFailure() {
        for event in projection.connectionFailed() {
            sink.yield(event)
        }
    }

    private func check(_ epoch: UUID) throws {
        try Task.checkCancellation()
        guard generation == epoch else { throw CancellationError() }
    }
}
