import ChatAPI
import ChatKit
import ChatService
import ChatServiceStorage
import FixtureBackend
import Foundation
import InProcessChatTransport
import ServiceClient
import SyncEngine
import Testing

actor Providers: AccountProviderFactory {
    private var backends: [ConnectedAccountID: FakeBackend] = [:]

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
                title: account.label
            )],
            messages: [],
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let backend = FakeBackend(world: world)
        backends[account.id] = backend
        return AccountProvider(backend: backend)
    }

    func forgetCredentials(for _: AccountRecord) {}

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
}

struct ClientHarness {
    let service: ChatService
    let providers: Providers
    let first: AccountSummary
    let second: AccountSummary
    let context: ServiceSessionContext

    static func make() async throws -> ClientHarness {
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
        let providers = Providers()
        let service = ChatService(
            registry: registry,
            storage: SQLiteServiceStorageFactory(directory: folder),
            providers: providers
        )
        try await service.restore()
        let context = ServiceSessionContext(
            principalID: first.principalID,
            deviceID: ServiceDeviceID("device"),
            sessionID: ClientSessionID("client"),
            accounts: [first.id, second.id]
        )
        let transport = InProcessChatTransport(endpoint: service, context: context)
        let client = AccountClient(transport: transport)
        for _ in 0 ..< 1000 {
            let accounts = try await client.accounts()
            if accounts.count == 2, accounts.allSatisfy({ $0.connection == .connected }) {
                let firstSummary = try #require(accounts.first { $0.id == first.id })
                let secondSummary = try #require(accounts.first { $0.id == second.id })
                return ClientHarness(
                    service: service,
                    providers: providers,
                    first: firstSummary,
                    second: secondSummary,
                    context: context
                )
            }
            await Task.yield()
        }
        throw ServiceFailure.deadlineExceeded
    }

    func backend(_ account: AccountSummary) -> ServiceBackend {
        ServiceBackend(
            account: account,
            transport: InProcessChatTransport(endpoint: service, context: context)
        )
    }
}

func eventually(_ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while ContinuousClock.now < deadline {
        try Task.checkCancellation()
        if try await predicate() {
            return
        }
        await Task.yield()
    }
    Issue.record("The expected service/replica state did not arrive before the deadline")
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
