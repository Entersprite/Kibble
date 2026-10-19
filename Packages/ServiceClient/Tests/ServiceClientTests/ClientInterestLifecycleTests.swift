import ChatAPI
import ChatKit
import Foundation
import InProcessChatTransport
import SyncEngine
import Testing
@testable import ChatService
@testable import ServiceClient

@Suite(.timeLimit(.minutes(1)))
struct ClientInterestLifecycleTests {
    @Test func expiredAttachmentRestoresReceiveAndDeviceIntentButNeverReplaysTyping() async throws {
        let harness = try await ClientHarness.make()
        let backend = harness.backend(harness.first)
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        try await engine.start()
        try await eventually { try store.me() == harness.first.selfID }
        let policy = try await backend.call(GetAccountPolicy())
        var settings = policy.settings
        settings.setRule(
            NotificationRule(sharesTyping: true),
            for: .global,
            at: Date(timeIntervalSince1970: 1_700_000_000),
            by: "device"
        )
        _ = try await backend.call(SetAccountPolicy(settings: settings, expectedRevision: policy.revision))
        try await backend.send(.watchPresence(members: [Member.ID("peer")]))
        try await backend.send(.watchConversationActivity(conversationID: Conversation.ID("same")))
        try await backend.send(.reportActivity(active: true))
        try await backend.send(.setTyping(
            conversationID: Conversation.ID("same"),
            threadID: nil,
            isTyping: true
        ))
        let runtime = try #require(await harness.service.runtimes[harness.first.id])
        try await eventually { await runtime.publishedInterests.typing.count == 1 }
        let original = try #require(await backend.attachment)
        await runtime.expireClientInterests(at: .now + .seconds(61))
        try await eventually {
            guard let current = await backend.attachment else { return false }
            return current.id != original.id
        }
        try await eventually {
            let current = await runtime.publishedInterests
            return current.active && current.presence == [Member.ID("peer")] &&
                current.conversations == [Conversation.ID("same")]
        }
        #expect(await runtime.publishedInterests.typing.isEmpty)
        await engine.stop()
        await harness.service.shutdown()
    }

    @Test func disconnectingOneAdapterLeavesAnotherAdaptersDeviceActivityOwned() async throws {
        let harness = try await ClientHarness.make()
        let first = harness.backend(harness.first), second = harness.backend(harness.first)
        let firstEngine = try SyncEngine(backend: first, store: ChatStore.inMemory())
        let secondEngine = try SyncEngine(backend: second, store: ChatStore.inMemory())
        try await firstEngine.start(); try await secondEngine.start()
        try await first.send(.reportActivity(active: true))
        try await second.send(.reportActivity(active: true))
        let runtime = try #require(await harness.service.runtimes[harness.first.id])
        try await eventually { await runtime.publishedInterests.active }
        await firstEngine.stop()
        #expect(await runtime.aggregateClientInterests().active)
        #expect(await harness.service.activeRuntimeCount == 2)
        await secondEngine.stop()
        try await eventually { await !runtime.publishedInterests.active }
        await harness.service.shutdown()
    }

    @Test func aLateAttachmentReplyIsRetiredAfterDisconnectWithoutOpeningAStream() async throws {
        let transport = HeldClientAttachmentTransport()
        let backend = ServiceBackend(account: AccountSummary(
            id: ConnectedAccountID("account"), selfID: Member.ID("self"), label: "Account",
            connection: .idle, revision: ServiceAccountRevision("binding")
        ), transport: transport)
        let connecting = Task { try await backend.connect() }
        try await eventually { await transport.entered }
        let disconnecting = Task { await backend.disconnect() }
        try await eventually { await backend.connecting == false }
        await transport.release()
        await #expect(throws: CancellationError.self) { try await connecting.value }
        await disconnecting.value
        #expect(await Set(transport.detached) == [ClientAttachmentID("late")])
        #expect(await transport.subscriptions == 0)
        #expect(await backend.attachment == nil)
    }

    @Test func cancelingOneHintDoesNotRetireTheConnectionsSharedOpeningLease() async throws {
        let transport = HeldClientAttachmentTransport()
        let backend = ServiceBackend(account: AccountSummary(
            id: ConnectedAccountID("account"), selfID: Member.ID("self"), label: "Account",
            connection: .idle, revision: ServiceAccountRevision("binding")
        ), transport: transport)
        let connecting = Task { try await backend.connect() }
        try await eventually { await transport.entered }
        let hint = Task { try await backend.send(.reportActivity(active: true)) }
        try await eventually { await backend.desiredInterests.activity != nil }
        hint.cancel()
        await transport.release()
        try await connecting.value
        await #expect(throws: CancellationError.self) { try await hint.value }
        #expect(await backend.attachment?.id == ClientAttachmentID("late"))
        #expect(await transport.detached.isEmpty)
        await backend.disconnect()
    }
}

private actor HeldClientAttachmentTransport: ServiceEventTransport {
    private(set) var entered = false
    private(set) var subscriptions = 0
    private(set) var detached: [ClientAttachmentID] = []
    private var continuation: CheckedContinuation<Void, Never>?
    func negotiate(_ version: ServiceAPIVersion) -> ServiceAPIVersion {
        version
    }

    func release() {
        continuation?.resume(); continuation = nil
    }

    func exchange(_ request: ServiceRequest) async throws -> ServiceResponse {
        switch request.operation {
        case AttachAccountClient.operation:
            entered = true
            await withCheckedContinuation { continuation = $0 }
            return try ServiceResponse(
                replyingTo: request,
                result: .success(ServiceCodec.value(ClientAttachment(
                    id: ClientAttachmentID("late"), expiresAt: Date().addingTimeInterval(60)
                )))
            )
        case DetachAccountClient.operation:
            try detached.append(request.decodePayload(DetachAccountClient.self).attachmentID)
            return try ServiceResponse(
                replyingTo: request,
                result: .success(ServiceCodec.value(ServiceUnit()))
            )
        default: return ServiceResponse(replyingTo: request, result: .failure(.unsupportedOperation))
        }
    }

    func events(_ request: ServiceRequest) -> AsyncThrowingStream<ServiceEventPage, any Error> {
        subscriptions += 1
        return AsyncThrowingStream { $0.finish() }
    }
}
