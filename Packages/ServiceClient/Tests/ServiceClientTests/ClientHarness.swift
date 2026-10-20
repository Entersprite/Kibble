import ChatAPI
import ChatKit
import ChatServiceStorage
import FixtureBackend
import Foundation
import InProcessChatTransport
import ServiceClient
import SyncEngine
import Testing
@testable import ChatService

actor Providers: AccountProviderFactory {
    let uploadMembership: Bool
    let threadUnreadClearing: Bool
    let providerUploadProgress: Bool

    init(
        uploadMembership: Bool = false, threadUnreadClearing: Bool = false,
        providerUploadProgress: Bool = false
    ) {
        self.uploadMembership = uploadMembership
        self.threadUnreadClearing = threadUnreadClearing
        self.providerUploadProgress = providerUploadProgress
    }

    private var backends: [ConnectedAccountID: FakeBackend] = [:]
    private var progressBackends: [ConnectedAccountID: UploadProgressBackend] = [:]

    func makeProvider(for account: AccountRecord) -> AccountProvider {
        let world = FixtureWorld(
            me: account.selfID,
            members: [
                Member(id: account.selfID, kind: .human, displayName: account.label),
                Member(id: Member.ID("peer"), kind: .human, displayName: "Peer")
            ],
            conversations: [Conversation(
                id: Conversation.ID("same"),
                kind: .space,
                title: account.label,
                members: uploadMembership ? [account.selfID, Member.ID("peer")] : []
            )],
            messages: [],
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        var capabilities = Capabilities.fixture
        capabilities.needsThreadUnreadClearBeforeRead = threadUnreadClearing && account.id.rawValue == "first"
        let backend = FakeBackend(world: world, capabilities: capabilities)
        backends[account.id] = backend
        if providerUploadProgress {
            let wrapper = UploadProgressBackend(inner: backend)
            progressBackends[account.id] = wrapper
            return AccountProvider(backend: wrapper)
        }
        return AccountProvider(backend: backend)
    }

    func forgetCredentials(for _: AccountRecord) {}

    func progressBackend(_ id: ConnectedAccountID) -> UploadProgressBackend? {
        progressBackends[id]
    }

    func incoming(_ account: ConnectedAccountID, count: Int) async throws {
        guard let backend = backends[account] else { throw ServiceFailure.accountNotFound }
        for index in 0 ..< count {
            try await backend.apply(.incomingMessage(
                conversation: Conversation.ID("same"),
                from: Member.ID("peer"),
                text: "Message \(index)",
                thread: nil
            ))
        }
    }

    func gap(_ account: ConnectedAccountID) async throws {
        guard let backend = backends[account] else { throw ServiceFailure.accountNotFound }
        try await backend.apply(.gap(scope: .conversation(Conversation.ID("same")), reason: "fixture gap"))
    }
}

struct ClientHarness {
    let service: ChatService
    let providers: Providers
    let first: AccountSummary
    let second: AccountSummary
    let context: ServiceSessionContext

    static func make(
        linkCustody: (any AccountLinkCustody)? = nil, uploads: Bool = false,
        transferLimits: ServiceTransferLimits = .init(), threadUnreadClearing: Bool = false,
        providerUploadProgress: Bool = false
    ) async throws -> ClientHarness {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let registry = try SQLiteAccountRegistry(path: folder.appendingPathComponent("registry.sqlite").path)
        let first = AccountRecord(
            id: ConnectedAccountID("first"),
            principalID: ServicePrincipalID("owner"),
            selfID: Member.ID("first-self"),
            label: "First",
            credentialGeneration: "one"
        )
        let second = AccountRecord(
            id: ConnectedAccountID("second"),
            principalID: first.principalID,
            selfID: Member.ID("second-self"),
            label: "Second",
            credentialGeneration: "one"
        )
        try registry.save(first)
        try registry.save(second)
        let providers = Providers(
            uploadMembership: uploads, threadUnreadClearing: threadUnreadClearing,
            providerUploadProgress: providerUploadProgress
        )
        let storage = SQLiteServiceStorageFactory(directory: folder)
        let service = ChatService(
            registry: registry,
            storage: storage,
            providers: providers,
            transferFiles: uploads ? DirectoryTransferStorageFactory(
                directory: folder.appendingPathComponent("files")
            ) : nil,
            transferLimits: transferLimits,
            linkCustody: linkCustody
        )
        try await service.restore()
        let context = ServiceSessionContext(
            principalID: first.principalID,
            deviceID: ServiceDeviceID("device"),
            sessionID: ClientSessionID("client"),
            accounts: [first.id, second.id], canLinkAccounts: linkCustody != nil
        )
        let transport = InProcessChatTransport(endpoint: service, context: context)
        let client = AccountClient(transport: transport)
        let accounts = try await readyAccounts(client)
        return try ClientHarness(
            service: service, providers: providers,
            first: #require(accounts.first { $0.id == first.id }),
            second: #require(accounts.first { $0.id == second.id }), context: context
        )
    }

    private static func readyAccounts(_ client: AccountClient) async throws -> [AccountSummary] {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let accounts = try await client.accounts()
            if accounts.count == 2, accounts.allSatisfy({ $0.connection == .connected }) {
                return accounts
            }
            await Task.yield()
        }
        throw ServiceFailure.deadlineExceeded
    }

    func canonical(_ account: ConnectedAccountID) async throws -> any ServiceAccountStorage {
        guard let runtime = await service.runtimes[account] else { throw ServiceFailure.accountNotFound }
        return await runtime.storage
    }

    func backend(_ account: AccountSummary) -> ServiceBackend {
        ServiceBackend(
            account: account,
            transport: InProcessChatTransport(endpoint: service, context: ServiceSessionContext(
                principalID: context.principalID, deviceID: context.deviceID,
                sessionID: ClientSessionID(UUID().uuidString), accounts: context.accounts
            ))
        )
    }
}

func eventually(
    sourceLocation: SourceLocation = #_sourceLocation, _ predicate: () async throws -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while ContinuousClock.now < deadline {
        try Task.checkCancellation()
        if try await predicate() {
            return
        }
        await Task.yield()
    }
    Issue.record(
        "The expected service/replica state did not arrive before the deadline",
        sourceLocation: sourceLocation
    )
    throw ServiceFailure.deadlineExceeded
}

actor AnnouncementLog {
    private(set) var arrivals: [SyncAnnouncement] = []
    func append(_ announcement: SyncAnnouncement) {
        if case .arrived = announcement {
            arrivals.append(announcement)
        }
    }
}
