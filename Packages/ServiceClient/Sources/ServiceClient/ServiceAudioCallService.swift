import ChatAPI
import ChatKit
import Foundation

/// A device-scoped API facade. Stopping this observer does not stop service media.
@MainActor
public final class ServiceAudioCallService: AudioCallService {
    public let events: AsyncStream<AudioCallEvent>
    private let sink: AsyncStream<AudioCallEvent>.Continuation
    private let client: AccountClient
    private let account: ConnectedAccountID
    private let revision: ServiceAccountRevision
    private var generation = UUID()
    private var observer: Task<Void, Never>?
    private var projection = ServiceCallStateProjection()

    public init(account: AccountSummary, client: AccountClient) throws {
        guard let revision = account.revision else { throw ServiceFailure.staleAccount }
        self.account = account.id; self.revision = revision; self.client = client
        (events, sink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
    }

    public func startListening() async throws {
        guard observer == nil else { return }
        let epoch = generation
        let initial = try await read(after: nil, wait: 0)
        try check(epoch)
        guard observer == nil else { return }
        try receive(initial)
        observer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, generation == epoch else { return }
                do {
                    let next = try await read(after: projection.version, wait: 20000)
                    try check(epoch)
                    try receive(next)
                } catch {
                    guard !Task.isCancelled, generation == epoch else { return }
                    sink.yield(.listenerChanged(isListening: false))
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                }
            }
        }
    }

    /// Provider-verified recipients arrive from the service; client hints grant nothing.
    public func updateRecipients(_: [AudioCallRecipient]) async {}

    public func startOutgoing(to recipient: AudioCallRecipient, callID: UUID) async throws {
        try await control(.init(action: "start", callID: callID, recipient: recipient))
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

    public func stop() async {
        generation = UUID()
        let pending = observer
        observer = nil
        pending?.cancel()
        await pending?.value
        projection = ServiceCallStateProjection()
    }

    private func read(after version: String?, wait: Int) async throws -> ServiceCallState {
        try await client.call(
            ReadCallState(after: version, waitMilliseconds: wait), account: account, revision: revision,
            timeout: 25
        )
    }

    private func control(_ request: ControlCall) async throws {
        let epoch = generation
        let result = try await client.call(request, account: account, revision: revision)
        try check(epoch)
        try receive(result)
    }

    private func receive(_ state: ServiceCallState) throws {
        for event in try projection.accept(state) {
            sink.yield(event)
        }
    }

    private func check(_ epoch: UUID) throws {
        try Task.checkCancellation()
        guard generation == epoch else { throw CancellationError() }
    }
}
