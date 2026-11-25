import ChatAPI
import ChatKit
import ChatServiceStorage
import Foundation
import InProcessChatTransport
import Synchronization
@testable import ChatService

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
    let context: ServiceSessionContext
    let attachment: ClientAttachment
    let hintSequence = TestHintSequence()

    static func make(
        backfill: Bool = false, holdHistory: Bool = false, policies: (any AccountPolicyStore)? = nil,
        reservations: OperationReservationCounter? = nil, checkpointing: Bool = false, webhooks: Bool = false,
        integrationsFlags: Set<String> = [], pins: Bool = false, startupFailures: [ChatError] = []
    ) async throws -> Self {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let registry = try SQLiteAccountRegistry(path: folder.appendingPathComponent("registry.sqlite").path)
        let record = LinkHarness.existing()
        try registry.save(record)
        let backend = ReconciliationBackend(
            backfill: backfill,
            holdHistory: holdHistory,
            checkpointing: checkpointing, webhooks: webhooks, integrationsFlags: integrationsFlags,
            pins: pins,
            startupFailures: startupFailures
        )
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
        let attachment = try await transport.exchange(ServiceRequest(header: ServiceRequestHeader(
            requestID: ServiceRequestID(UUID().uuidString), accountID: record.id,
            accountRevision: record.currentRevision, deadline: Date().addingTimeInterval(5)
        ), payload: AttachAccountClient(generation: "1"))).value(for: AttachAccountClient.self)
        return Self(
            record: record,
            backend: backend,
            registry: registry,
            storage: accountStorage,
            service: service,
            transport: transport, context: context, attachment: attachment
        )
    }

    func call<P: ServiceRequestPayload>(_ payload: P) async throws -> P.Response {
        try await transport.exchange(ServiceRequest(header: ServiceRequestHeader(
            requestID: ServiceRequestID(UUID().uuidString), accountID: record.id,
            accountRevision: record.currentRevision, deadline: Date().addingTimeInterval(60)
        ), payload: payload)).value(for: P.self)
    }

    func history() throws -> [Message] {
        try storage.recentHistory(in: ReconciliationBackend.conversation, limit: 200)
    }

    func hint(_ command: ChatCommand) async throws {
        _ = try await call(SendHint(
            command: command,
            attachmentID: attachment.id,
            sequence: hintSequence.next()
        ))
    }

    func addConversation(_ id: Conversation.ID) async throws {
        await backend.addConversation(id)
        try await authEventually { try storage.conversation(id) != nil }
    }
}

final class TestHintSequence: Sendable {
    private let value = Mutex<UInt64>(0)
    func next() -> String {
        value.withLock { $0 += 1; return String($0) }
    }
}
