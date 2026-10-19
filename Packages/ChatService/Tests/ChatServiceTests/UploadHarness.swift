import ChatAPI
import ChatKit
import ChatService
import ChatServiceStorage
import FixtureBackend
import Foundation
import InProcessChatTransport

actor UploadTestBackend: ChatBackend {
    nonisolated let capabilities = Capabilities.fixture
    nonisolated let events: AsyncStream<ChatEvent>
    let inner: FakeBackend
    private(set) var uploaded: [Data] = []
    private(set) var files: [URL] = []
    private(set) var sends: [ChatCommand] = []
    var isMember = true
    var hold = false
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var held = false
    private(set) var acknowledged = false

    init(selfID: Member.ID) {
        let world = FixtureWorld(
            me: selfID, members: [Member(id: selfID, kind: .human, displayName: "Demo")],
            conversations: ["conversation", "other"].map {
                Conversation(id: .init($0), kind: .space, members: [selfID])
            }, messages: [], startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        inner = FakeBackend(world: world)
        events = inner.events
    }

    func connect() async throws {
        try await inner.connect()
    }

    func disconnect() async {
        await inner.disconnect()
    }

    func loadConversations() async throws -> [Conversation] {
        try await inner.loadConversations()
    }

    func loadMessages(in id: Conversation.ID, before: Message.ID?) async throws -> [Message] {
        try await inner.loadMessages(in: id, before: before)
    }

    func setNotificationSetting(_ level: NotificationLevel, for id: Conversation.ID) async throws {
        try await inner.setNotificationSetting(level, for: id)
    }

    func send(_ command: ChatCommand) async throws {
        sends.append(command); try await inner.send(command)
    }

    func membership(
        of _: Member.ID,
        in _: Conversation.ID
    ) -> ConversationMembership {
        isMember ? .member : .notMember
    }

    func setMember(_ value: Bool) {
        isMember = value
    }

    func holdUploads() {
        hold = true
    }

    func release() {
        waiter?.resume(); waiter = nil; hold = false
    }

    func uploadAttachment(
        _ attachment: OutgoingAttachment, to conversation: Conversation.ID,
        progress: @escaping @Sendable (AttachmentProgress) -> Void
    ) async throws -> Attachment {
        try uploaded.append(Data(contentsOf: attachment.file))
        files.append(attachment.file)
        if hold {
            held = true
            await withCheckedContinuation { waiter = $0 }
            acknowledged = true
            // The remote request was handed off before disconnect; its reply can still succeed.
            return Attachment(
                id: "held-upload",
                name: attachment.name,
                contentType: attachment.contentType,
                byteSize: attachment.byteSize
            )
        }
        return try await inner.uploadAttachment(attachment, to: conversation, progress: progress)
    }
}

actor UploadTestProviders: AccountProviderFactory {
    private var backends: [ConnectedAccountID: UploadTestBackend] = [:]
    func makeProvider(for account: AccountRecord) -> AccountProvider {
        let backend = UploadTestBackend(selfID: account.selfID)
        backends[account.id] = backend
        return AccountProvider(backend: backend)
    }

    func backend(_ id: ConnectedAccountID) -> UploadTestBackend? {
        backends[id]
    }

    func forgetCredentials(for _: AccountRecord) {}
}

struct UploadHarness {
    let service: ChatService
    let transport: InProcessChatTransport
    let providers: UploadTestProviders
    let first: AccountRecord
    let second: AccountRecord
    let files: any ServiceTransferStorageFactory
    let directory: URL

    static func make(
        limits: ServiceTransferLimits = .init(), now: @escaping @Sendable () -> Date = { Date() },
        fileFactory: (@Sendable (URL) -> any ServiceTransferStorageFactory)? = nil
    ) async throws -> UploadHarness {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let registry = try SQLiteAccountRegistry(path: directory.appendingPathComponent("registry.sqlite")
            .path)
        let principal = ServicePrincipalID("principal")
        let accounts = ["first", "second"].map {
            AccountRecord(
                id: .init($0),
                principalID: principal,
                selfID: .init("self-\($0)"),
                label: $0,
                credentialGeneration: "generation"
            )
        }
        for account in accounts {
            try registry.save(account)
        }
        let files = fileFactory?(directory.appendingPathComponent("files"))
            ?? DirectoryTransferStorageFactory(directory: directory.appendingPathComponent("files"))
        let providers = UploadTestProviders()
        let service = ChatService(
            registry: registry, storage: SQLiteServiceStorageFactory(directory: directory),
            providers: providers,
            transferFiles: files, transferLimits: limits, transferNow: now
        )
        try await service.restore()
        let context = ServiceSessionContext(
            principalID: principal, deviceID: .init("device"), sessionID: .init("session"),
            accounts: Set(accounts.map(\.id))
        )
        let transport = InProcessChatTransport(endpoint: service, context: context)
        _ = try await transport.negotiate(.current)
        let harness = UploadHarness(
            service: service,
            transport: transport,
            providers: providers,
            first: accounts[0],
            second: accounts[1],
            files: files,
            directory: directory
        )
        try await harness.waitReady()
        return harness
    }

    private func waitReady() async throws {
        for _ in 0 ..< 1000 {
            let listed = try await call(ListAccounts())
            if listed.allSatisfy({ $0.capabilities.canSendAttachments && $0.connection == .connected }) {
                let rows = try await call(LoadConversations(), account: first)
                if rows.count == 2 {
                    return
                }
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        await service.shutdown()
        throw ServiceFailure.deadlineExceeded
    }

    func request(_ payload: some ServiceRequestPayload, account: AccountRecord) throws -> ServiceRequest {
        try ServiceRequest(header: ServiceRequestHeader(
            requestID: .init(UUID().uuidString), accountID: account.id,
            accountRevision: account.currentRevision,
            deadline: Date().addingTimeInterval(10)
        ), payload: payload)
    }

    func call<P: ServiceRequestPayload>(_ payload: P, account: AccountRecord? = nil) async throws -> P
        .Response {
        let request: ServiceRequest = if let account {
            try self.request(payload, account: account)
        } else {
            try ServiceRequest(header: .init(requestID: .init(UUID().uuidString)), payload: payload)
        }
        return try await transport.exchange(request).value(for: P.self)
    }

    func begin(
        _ size: Int,
        account: AccountRecord? = nil,
        operation: String = "begin"
    ) async throws -> UploadTransfer {
        try await call(BeginUploadTransfer(
            operationID: .init(operation), conversationID: .init("conversation"),
            metadata: UploadFileMetadata(
                name: "chosen file",
                contentType: "application/octet-stream",
                byteSize: size
            )
        ), account: account ?? first)
    }

    func write(
        _ transfer: UploadTransfer,
        bytes: Data,
        offset: Int64 = 0,
        account: AccountRecord? = nil
    ) async throws {
        let request = try request(
            WriteTransferChunk(transferID: transfer.id, offset: offset, count: bytes.count),
            account: account ?? first
        )
        let result = try await transport.exchangeBinary(request, body: bytes)
        _ = try result.response.value(for: WriteTransferChunk.self)
    }
}
