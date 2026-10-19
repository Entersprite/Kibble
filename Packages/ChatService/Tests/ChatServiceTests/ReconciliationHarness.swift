import ChatAPI
import ChatKit
import ChatServiceStorage
import Foundation
import InProcessChatTransport
@testable import ChatService

actor ReconciliationBackend: ChatBackend {
    nonisolated let capabilities: Capabilities
    nonisolated let events: AsyncStream<ChatEvent>
    private let sink: AsyncStream<ChatEvent>.Continuation
    private var rows: [Conversation]
    private var history: [Message]
    private var holdWorld = false
    private var holdHistory = false
    private var worldWaiter: CheckedContinuation<Void, Never>?
    private var historyWaiter: CheckedContinuation<Void, Never>?
    private(set) var worldHeld = false
    private(set) var historyHeld = false
    private(set) var worldReads = 0
    private(set) var historyReads = 0
    private(set) var sentCommands: [ChatCommand] = []

    static let date = Date(timeIntervalSince1970: 1_700_000_000)
    static let conversation = Conversation.ID("shared")
    static let message = Message(
        id: Message.ID("message"), conversationID: conversation, threadID: MessageThread.ID("thread"),
        sender: Member.ID("peer"), text: "Original", createdAt: date
    )

    init(backfill: Bool = false, holdHistory: Bool = false) {
        capabilities = Capabilities(needsMentionBackfill: backfill)
        self.holdHistory = holdHistory
        rows = [Conversation(id: Self.conversation, kind: .space, title: "Original", lastActivity: Self.date)]
        history = [Self.message]
        (events, sink) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(128))
    }

    func connect() {
        sink.yield(.connectionStateChanged(.connected))
    }

    func disconnect() {}
    func send(_ command: ChatCommand) {
        sentCommands.append(command)
    }

    func holdNextWorld() {
        holdWorld = true
    }

    func holdNextHistory() {
        holdHistory = true
    }

    func releaseWorld() {
        worldWaiter?.resume(); worldWaiter = nil
    }

    func releaseHistory() {
        historyWaiter?.resume(); historyWaiter = nil
    }

    func emit(_ event: ChatEvent) {
        sink.yield(event)
    }

    func removeConversation() {
        rows = []
        sink.yield(.conversationRemoved(conversationID: Self.conversation, historyBefore: nil))
    }

    func deleteMessage() {
        history[0].isDeleted = true
        sink.yield(.messageDeleted(id: Self.message.id, in: Self.conversation))
    }

    func loadConversations() async -> [Conversation] {
        worldReads += 1
        let captured = rows
        if holdWorld {
            holdWorld = false; worldHeld = true
            await withCheckedContinuation { worldWaiter = $0 }
        }
        return captured
    }

    func loadMessages(in conversation: Conversation.ID, before: Message.ID?) async -> [Message] {
        historyReads += 1
        let captured = history
        if holdHistory {
            holdHistory = false; historyHeld = true
            await withCheckedContinuation { historyWaiter = $0 }
        }
        return captured
    }

    func setNotificationSetting(_ level: NotificationLevel, for conversation: Conversation.ID) {}
}

struct ReconciliationProviders: AccountProviderFactory {
    let backend: ReconciliationBackend
    func makeProvider(for account: AccountRecord) -> AccountProvider {
        AccountProvider(backend: backend, now: { ReconciliationBackend.date })
    }

    func forgetCredentials(for account: AccountRecord) {}
}

struct ReconciliationHarness {
    let record: AccountRecord
    let backend: ReconciliationBackend
    let registry: SQLiteAccountRegistry
    let storage: any ServiceAccountStorage
    let service: ChatService
    let transport: InProcessChatTransport

    static func make(
        backfill: Bool = false, holdHistory: Bool = false, policies: (any AccountPolicyStore)? = nil,
        reservations: OperationReservationCounter? = nil
    ) async throws -> Self {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let registry = try SQLiteAccountRegistry(path: folder.appendingPathComponent("registry.sqlite").path)
        let record = LinkHarness.existing()
        try registry.save(record)
        let backend = ReconciliationBackend(backfill: backfill, holdHistory: holdHistory)
        var storage: any ServiceStorageFactory = SQLiteServiceStorageFactory(directory: folder)
        if let reservations {
            storage = CountedStorageFactory(backing: storage, reservations: reservations)
        }
        let service = ChatService(
            registry: registry,
            storage: storage,
            providers: ReconciliationProviders(backend: backend), policies: policies
        )
        try await service.restore()
        let context = ServiceSessionContext(
            principalID: record.principalID, deviceID: ServiceDeviceID("device"),
            sessionID: ClientSessionID("client"),
            accounts: [record.id]
        )
        let transport = InProcessChatTransport(endpoint: service, context: context)
        _ = try await transport.negotiate(.current)
        guard let runtime = await service.runtimes[record.id] else { throw ServiceFailure.accountNotFound }
        let accountStorage = await runtime.storage
        return Self(
            record: record,
            backend: backend,
            registry: registry,
            storage: accountStorage,
            service: service,
            transport: transport
        )
    }

    func call<P: ServiceRequestPayload>(_ payload: P) async throws -> P.Response {
        try await transport.exchange(ServiceRequest(header: ServiceRequestHeader(
            requestID: ServiceRequestID(UUID().uuidString), accountID: record.id,
            accountRevision: record.currentRevision
        ), payload: payload)).value(for: P.self)
    }

    func history() throws -> [Message] {
        try storage.recentHistory(in: ReconciliationBackend.conversation, limit: 200)
    }
}
