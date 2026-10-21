import ChatAPI
import ChatKit
import Foundation
import Testing
@testable import ServiceClient

@Suite(.timeLimit(.minutes(1)))
struct ReplayPageTests {
    @Test func historicalFailureAndRecoveryShareOneReplicaCommitButLiveFailuresRemainVisible() async throws {
        let events: [ChatEvent] = [
            .connectionStateChanged(.disconnected(reason: nil, issue: nil)),
            .backendError(.transport("Previous outage")),
            .messageUpdated(Message(
                id: .init("message"), conversationID: .init("conversation"), threadID: .init("thread"),
                sender: .init("peer"), text: "Saved message", createdAt: Date(timeIntervalSince1970: 1)
            )),
            .connectionStateChanged(.connecting)
        ]
        let transport = ReplayPageTransport(events: events)
        let backend = ServiceBackend(account: transport.account, transport: transport)
        let stream = await backend.useCheckpointedDeliveries(after: transport.position(0).replicaCheckpoint)
        var iterator = stream.makeAsyncIterator()
        defer { Task { await backend.disconnect() } }
        try await backend.connect()
        let replay = try #require(await iterator.next())
        try #require(replay.events == events)
        #expect(replay.checkpoint?.sequence == 4)
        #expect(!replay.isLive)
        #expect(await backend.cursor == transport.position(0))
        try await backend.acknowledge(#require(replay.checkpoint), applied: true)
        try await eventually { await backend.cursor == transport.position(4) }
        let currentFailure = ChatEvent.backendError(.transport("Current outage"))
        await transport.send(ServiceEventPage(
            checkpoint: transport.position(5), snapshot: nil,
            events: [.init(cursor: transport.position(5), event: currentFailure, isLiveArrival: true)],
            hasMore: false
        ))
        let live = try #require(await iterator.next())
        #expect(live.isLive)
        #expect(live.events == [currentFailure])
        try await backend.acknowledge(#require(live.checkpoint), applied: true)
        await backend.disconnect()
    }

    @Test func aBrokenReplaySequenceDoesNotPublishAPartialPage() async throws {
        let transport = ReplayPageTransport(events: [.connectionStateChanged(.connecting)], sequence: 2)
        let backend = ServiceBackend(account: transport.account, transport: transport)
        let stream = await backend.useCheckpointedDeliveries(after: transport.position(0).replicaCheckpoint)
        var iterator = stream.makeAsyncIterator()
        defer { Task { await backend.disconnect() } }
        try await backend.connect()
        let unavailable = try #require(await iterator.next())
        #expect(unavailable.events.isEmpty)
        #expect(unavailable.checkpoint == nil)
        #expect(unavailable.clientTransportAvailable == false)
        #expect(await backend.cursor == transport.position(0))
        await backend.disconnect()
    }
}

private actor ReplayPageTransport: ServiceEventTransport {
    nonisolated let account = AccountSummary(
        id: .init("account"), selfID: .init("self"), label: "Acme",
        connection: .connecting, revision: .init("binding")
    )
    let initial: [ChatEvent]
    let sequence: Int
    var sink: AsyncThrowingStream<ServiceEventPage, any Error>.Continuation?

    init(events: [ChatEvent], sequence: Int = 1) {
        initial = events; self.sequence = sequence
    }

    nonisolated func position(_ sequence: Int) -> ServiceCursor {
        ServiceCursor(accountID: account.id, streamID: .init("stream"), sequence: UInt64(sequence))
    }

    func negotiate(_ version: ServiceAPIVersion) -> ServiceAPIVersion {
        version
    }

    func exchange(_ request: ServiceRequest) throws -> ServiceResponse {
        switch request.operation {
        case AttachAccountClient.operation:
            try ServiceResponse(replyingTo: request, result: .success(ServiceCodec.value(ClientAttachment(
                id: .init("lease"), expiresAt: Date().addingTimeInterval(60)
            ))))
        case DetachAccountClient.operation:
            try ServiceResponse(replyingTo: request, result: .success(ServiceCodec.value(ServiceUnit())))
        default: ServiceResponse(replyingTo: request, result: .failure(.unsupportedOperation))
        }
    }

    func events(_ request: ServiceRequest) -> AsyncThrowingStream<ServiceEventPage, any Error> {
        let (stream, sink) = AsyncThrowingStream<ServiceEventPage, any Error>.makeStream()
        self.sink = sink
        let events = initial.enumerated().map { index, event in
            ServiceEvent(cursor: position(sequence + index), event: event, isLiveArrival: false)
        }
        sink.yield(ServiceEventPage(
            checkpoint: events.last?.cursor ?? position(0), snapshot: nil, events: events, hasMore: false
        ))
        return stream
    }

    func send(_ page: ServiceEventPage) {
        sink?.yield(page)
    }
}
