import ChatAPI
import ChatKit
import ChatService
import ChatServiceStorage
import Foundation
import InProcessChatTransport
import Testing

actor AuthBackend: ChatBackend {
    nonisolated let capabilities = Capabilities()
    nonisolated let events: AsyncStream<ChatEvent>
    private let sink: AsyncStream<ChatEvent>.Continuation
    let record: AccountRecord
    private let holdConnect: Bool
    private var connectReleased = false
    private var connectWaiter: CheckedContinuation<Void, Never>?
    private(set) var began = false
    private(set) var connected = false
    private(set) var disconnects = 0
    var queryFailure: ChatError?

    init(record: AccountRecord, holdConnect: Bool = false) {
        self.record = record
        self.holdConnect = holdConnect
        (events, sink) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(32))
    }

    func connect() async {
        began = true
        if holdConnect, !connectReleased {
            await withCheckedContinuation { connectWaiter = $0 }
        }
        connected = true
        sink.yield(.selfIdentified(Member(id: record.selfID, kind: .human, displayName: record.label)))
        sink.yield(.conversationsChanged([conversation]))
        sink.yield(.connectionStateChanged(.connected))
    }

    func disconnect() {
        disconnects += 1
        connected = false
        sink.yield(.connectionStateChanged(.disconnected(reason: nil, issue: nil)))
    }

    func releaseConnect() {
        connectReleased = true; connectWaiter?.resume(); connectWaiter = nil
    }

    func fail(_ event: ChatEvent) {
        sink.yield(event)
    }

    func failQueries(_ error: ChatError) {
        queryFailure = error
    }

    func send(_ command: ChatCommand) {}
    func loadConversations() throws -> [Conversation] {
        if let queryFailure {
            throw queryFailure
        }
        return [conversation]
    }

    func loadMessages(in conversation: Conversation.ID, before cursor: Message.ID?) -> [Message] {
        []
    }

    func setNotificationSetting(_ level: NotificationLevel, for conversation: Conversation.ID) throws {
        throw ChatError.unsupported(capability: "canSetNotifications")
    }

    private var conversation: Conversation {
        .init(
            id: Conversation.ID("private"),
            kind: .space,
            title: record.label
        )
    }
}

actor AuthProviders: AccountProviderFactory {
    private var backends: [ConnectedAccountID: AuthBackend] = [:]
    private var startupFailures: [Member.ID: ChatError] = [:]
    var forgetFailures = 0
    var holdForget = false
    var holdConnect = false
    private var forgetReleased = false
    private var forgetWaiter: CheckedContinuation<Void, Never>?
    private(set) var attempts: [ConnectedAccountID: Int] = [:]
    private(set) var forgotten: Set<ConnectedAccountID> = []
    private(set) var forgottenGenerations: [String] = []
    private(set) var forgetAttempts = 0

    func configure(
        identity: Member.ID? = nil,
        failure: ChatError? = nil,
        forgetFailures: Int = 0,
        holdForget: Bool = false,
        holdConnect: Bool = false
    ) {
        if let identity {
            startupFailures[identity] = failure
        }
        self.forgetFailures = forgetFailures
        self.holdForget = holdForget
        self.holdConnect = holdConnect
    }

    func makeProvider(for account: AccountRecord) throws -> AccountProvider {
        attempts[account.id, default: 0] += 1
        if let failure = startupFailures[account.selfID] {
            throw failure
        }
        let backend = AuthBackend(record: account, holdConnect: holdConnect)
        backends[account.id] = backend
        return AccountProvider(backend: backend)
    }

    func hasBackend(_ account: ConnectedAccountID) -> Bool {
        backends[account] != nil
    }

    func backend(_ account: ConnectedAccountID) throws -> AuthBackend {
        guard let backend = backends[account] else { throw ServiceFailure.accountNotFound }
        return backend
    }

    func forgetCredentials(for account: AccountRecord) async throws {
        forgetAttempts += 1
        if holdForget, !forgetReleased {
            await withCheckedContinuation { forgetWaiter = $0 }
        }
        if forgetFailures > 0 {
            forgetFailures -= 1; throw ServiceFailure.internalFailure
        }
        forgotten.insert(account.id)
        forgottenGenerations.append(account.credentialGeneration)
    }

    func releaseForget() {
        forgetReleased = true; forgetWaiter?.resume(); forgetWaiter = nil
    }
}

struct AuthHarness {
    let folder: URL
    let registry: SQLiteAccountRegistry
    let storage: SQLiteServiceStorageFactory
    let providers: AuthProviders
    let custody: TestLinkCustody
    let service: ChatService
    let context: ServiceSessionContext
    let transport: InProcessChatTransport
    let first: AccountRecord
    let second: AccountRecord

    static func make(
        providers: AuthProviders = AuthProviders(),
        firstAuthenticationState: String? = nil
    ) async throws -> AuthHarness {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let registry = try SQLiteAccountRegistry(path: folder.appendingPathComponent("registry.sqlite").path)
        var first = LinkHarness.existing()
        first.authenticationState = firstAuthenticationState
        let second = AccountRecord(
            id: ConnectedAccountID("second"),
            principalID: first.principalID,
            selfID: Member.ID("second-self"),
            label: "Second",
            credentialGeneration: "second-generation"
        )
        try registry.save(first)
        try registry.save(second)
        let storage = SQLiteServiceStorageFactory(directory: folder)
        let custody = TestLinkCustody()
        let service = ChatService(
            registry: registry,
            storage: storage,
            providers: providers,
            linkCustody: custody
        )
        try await service.restore()
        let context = ServiceSessionContext(
            principalID: first.principalID,
            deviceID: ServiceDeviceID("device"),
            sessionID: ClientSessionID("session"),
            accounts: [],
            hasAllAccountAccess: true,
            canLinkAccounts: true
        )
        let transport = InProcessChatTransport(endpoint: service, context: context)
        _ = try await transport.negotiate(.current)
        return AuthHarness(
            folder: folder,
            registry: registry,
            storage: storage,
            providers: providers,
            custody: custody,
            service: service,
            context: context,
            transport: transport,
            first: first,
            second: second
        )
    }

    func call<P: ServiceRequestPayload>(_ payload: P, account: ConnectedAccountID? = nil) async throws -> P
        .Response {
        let revision = try account
            .flatMap { id in try registry.accounts().first { $0.id == id }?.currentRevision }
        let request = try ServiceRequest(
            header: ServiceRequestHeader(
                requestID: ServiceRequestID(UUID().uuidString),
                accountID: account,
                accountRevision: revision
            ),
            payload: payload
        )
        return try await transport.exchange(request).value(for: P.self)
    }

    func backend(_ account: ConnectedAccountID) async throws -> AuthBackend {
        try await authEventually { await providers.hasBackend(account) }
        return try await providers.backend(account)
    }

    func restarted(
        providers: AuthProviders, storageOverride: (any ServiceStorageFactory)? = nil,
        registryOverride: (any AccountRegistry)? = nil
    ) async throws -> AuthHarness {
        await service.shutdown()
        let service = ChatService(
            registry: registryOverride ?? registry,
            storage: storageOverride ?? storage,
            providers: providers,
            linkCustody: custody, policies: registry
        )
        try await service.restore()
        let transport = InProcessChatTransport(endpoint: service, context: context)
        _ = try await transport.negotiate(.current)
        return AuthHarness(
            folder: folder,
            registry: registry,
            storage: storage,
            providers: providers,
            custody: custody,
            service: service,
            context: context,
            transport: transport,
            first: first,
            second: second
        )
    }

    func ready(_ account: ConnectedAccountID) async throws {
        try await authEventually {
            let page = try await call(ReadEvents(cursor: nil, limit: 1), account: account)
            return page.snapshot?
                .contains {
                    if case let .conversationsChanged(rows) = $0 {
                        return !rows.isEmpty
                    }; return false
                } == true
        }
    }

    func state(_ account: ConnectedAccountID) throws -> String? {
        try registry.accounts()
            .first { $0.id == account }?.authenticationState
    }
}

func authEventually(_ predicate: () async throws -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(5)
    while clock.now < deadline {
        if try await predicate() {
            return
        }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw ServiceFailure.deadlineExceeded
}
