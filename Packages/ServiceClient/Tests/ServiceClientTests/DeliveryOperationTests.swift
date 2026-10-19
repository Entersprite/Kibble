import ChatAPI
import ChatKit
import ChatService
import ChatServiceStorage
import Foundation
import InProcessChatTransport
import ServiceClient
import SyncEngine
import Testing

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct DeliveryOperationTests {
    @Test(arguments: [false, true])
    func lostMalformedReplyKeepsOriginalMessageAndChecksSucceededLedgerWithoutResending(
        _ unknownReply: Bool
    ) async throws {
        let harness = try await DeliveryLedgerHarness.make(uncertainProvider: false)
        let transport = LostDeliveryReplyTransport(base: harness.transport, unknownReply: unknownReply)
        let backend = ServiceBackend(account: harness.account, transport: transport)
        let store = try ChatStore.inMemory()
        let model = ChatSessionModel(
            store: store,
            engine: SyncEngine(backend: backend, store: store),
            me: harness.account.selfID
        )
        try await model.start()
        try await wait { !model.conversations.isEmpty && model.me == harness.account.selfID }
        model.select(DeliveryLedgerBackend.conversation)
        model.send(ComposedMessage(text: "Original message with a lost reply"))
        try await wait { model.messageDeliveryStatuses.values.contains(.unconfirmed) }
        #expect(model.failedDraft == nil)
        let pending = try #require(try store.messageDeliveries().first)
        model.checkMessageDelivery(pending.messageID)
        try await wait { model.messageDeliveryStatuses[pending.messageID] == .sent }
        #expect(await harness.provider.sendCount == 1)
        #expect(await transport.submissions == 1)
        #expect(await transport.statusReads == 1)
        #expect(try store.message(pending.messageID)?.text == "Original message with a lost reply")
        await model.stop()
        await harness.service.shutdown()
    }

    @Test func unknownProviderOutcomeSurvivesClientRestartWithoutAnotherSend() async throws {
        let harness = try await DeliveryLedgerHarness.make(uncertainProvider: true)
        let store = try ChatStore.inMemory()
        let firstBackend = ServiceBackend(account: harness.account, transport: harness.transport)
        let first = ChatSessionModel(
            store: store,
            engine: SyncEngine(backend: firstBackend, store: store),
            me: harness.account.selfID
        )
        try await first.start()
        try await wait { !first.conversations.isEmpty && first.me == harness.account.selfID }
        first.select(DeliveryLedgerBackend.conversation)
        first.send(ComposedMessage(text: "One uncertain provider dispatch"))
        try await wait { first.messageDeliveryStatuses.values.contains(.unconfirmed) }
        let original = try #require(try store.messageDeliveries().first)
        await first.stop()
        let secondBackend = ServiceBackend(account: harness.account, transport: harness.newTransport())
        let second = ChatSessionModel(
            store: store,
            engine: SyncEngine(backend: secondBackend, store: store),
            me: harness.account.selfID
        )
        try await second.start()
        try await wait { second.messageDeliveryStatuses[original.messageID] == .unconfirmed }
        second.checkMessageDelivery(original.messageID)
        try await wait { !second.checkingMessageDeliveries.contains(original.messageID) }
        #expect(await harness.provider.sendCount == 1)
        #expect(try store.message(original.messageID)?.localID == original.localID)
        #expect(second.failedDraft == nil)
        await second.stop()
        await harness.service.shutdown()
    }

    private func wait(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw ServiceFailure.deadlineExceeded
    }
}

private struct DeliveryLedgerHarness {
    let service: ChatService
    let provider: DeliveryLedgerBackend
    let account: AccountSummary
    let transport: InProcessChatTransport
    let context: ServiceSessionContext
    func newTransport() -> InProcessChatTransport {
        InProcessChatTransport(
            endpoint: service,
            context: ServiceSessionContext(
                principalID: context.principalID,
                deviceID: context.deviceID,
                sessionID: ClientSessionID(UUID()
                    .uuidString),
                accounts: context.accounts
            )
        )
    }

    static func make(uncertainProvider: Bool) async throws -> Self {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let registry = try SQLiteAccountRegistry(path: folder.appendingPathComponent("registry.sqlite").path)
        let account = AccountRecord(
            id: ConnectedAccountID("account"),
            principalID: ServicePrincipalID("owner"),
            selfID: Member.ID("self"),
            label: "Account",
            credentialGeneration: "generation"
        )
        try registry.save(account)
        let provider = DeliveryLedgerBackend(uncertain: uncertainProvider)
        let service = ChatService(
            registry: registry,
            storage: SQLiteServiceStorageFactory(directory: folder),
            providers: DeliveryLedgerFactory(backend: provider)
        )
        try await service.restore()
        let context = ServiceSessionContext(
            principalID: account.principalID, deviceID: ServiceDeviceID("device"),
            sessionID: ClientSessionID("client"), accounts: [account.id]
        )
        let transport = InProcessChatTransport(endpoint: service, context: context)
        let client = AccountClient(transport: transport)
        try await eventually { try await client.accounts().first?.connection == .connected }
        return try Self(
            service: service,
            provider: provider,
            account: #require(try await client.accounts().first),
            transport: transport,
            context: context
        )
    }
}

private struct DeliveryLedgerFactory: AccountProviderFactory {
    let backend: DeliveryLedgerBackend
    func makeProvider(for account: AccountRecord) -> AccountProvider {
        AccountProvider(backend: backend)
    }

    func forgetCredentials(for account: AccountRecord) {}
}

private actor DeliveryLedgerBackend: ChatBackend {
    static let conversation = Conversation.ID("conversation")
    nonisolated let capabilities = Capabilities(canSendMessages: true)
    nonisolated let events: AsyncStream<ChatEvent>
    private let continuation: AsyncStream<ChatEvent>.Continuation
    private let uncertain: Bool
    private(set) var sendCount = 0
    init(uncertain: Bool) {
        self.uncertain = uncertain
        (events, continuation) = AsyncStream.makeStream()
    }

    func connect() {
        continuation.yield(.selfIdentified(Member(id: Member.ID("self"), kind: .human)))
        continuation.yield(.conversationsChanged(loadConversations()))
        continuation.yield(.connectionStateChanged(.connected))
    }

    func disconnect() {}
    func send(_ command: ChatCommand) throws {
        if case .sendMessage = command {
            sendCount += 1
            if uncertain {
                throw ChatError.server(status: 500, message: "Provider reply was lost")
            }
            // An accepted send can precede its channel echo. Deliberately do
            // not fabricate one to hide the pending UI in the lost-reply test.
        }
    }

    func loadConversations() -> [Conversation] {
        [Conversation(
            id: Self.conversation,
            kind: .space,
            title: "Conversation",
            members: [Member.ID("self")]
        )]
    }

    func loadMessages(in conversation: Conversation.ID, before: Message.ID?) -> [Message] {
        []
    }

    func setNotificationSetting(_ level: NotificationLevel, for conversation: Conversation.ID) {}
}

private actor LostDeliveryReplyTransport: ServiceEventTransport {
    let base: InProcessChatTransport
    let unknownReply: Bool
    private(set) var submissions = 0
    private(set) var statusReads = 0
    init(base: InProcessChatTransport, unknownReply: Bool) {
        self.base = base
        self.unknownReply = unknownReply
    }

    func negotiate(_ version: ServiceAPIVersion) async throws -> ServiceAPIVersion {
        try await base
            .negotiate(version)
    }

    func events(_ request: ServiceRequest) async throws -> AsyncThrowingStream<ServiceEventPage, any Error> {
        try await base.events(request)
    }

    func exchange(_ request: ServiceRequest) async throws -> ServiceResponse {
        let result = try await base.exchange(request)
        if request.operation == GetOperation.operation {
            statusReads += 1
        }
        if request.operation == SendCommand.operation {
            submissions += 1
            if submissions == 1 {
                if unknownReply {
                    let response = ServiceResponse(
                        replyingTo: request,
                        result: .unknown(
                            type: "futureResult",
                            payload: .object(["extra": .bool(true)])
                        )
                    )
                    return try ServiceCodec.decode(ServiceResponse.self, from: ServiceCodec.encode(response))
                }
                throw ServiceFailure.invalidResponse
            }
        }
        return result
    }
}
