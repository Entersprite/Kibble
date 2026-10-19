import ChatAPI
import ChatKit
import ChatService
import ChatServiceStorage
import FixtureBackend
import Foundation
import InProcessChatTransport
import Testing

actor TestProviders: AccountProviderFactory {
    private(set) var made: [ConnectedAccountID: Int] = [:]
    private(set) var forgotten: Set<ConnectedAccountID> = []
    private var forgetFailures: Int

    init(forgetFailures: Int = 0) {
        self.forgetFailures = forgetFailures
    }

    func makeProvider(for account: AccountRecord) -> AccountProvider {
        made[account.id, default: 0] += 1
        let world = FixtureWorld(
            me: account.selfID,
            members: [Member(id: account.selfID, kind: .human, displayName: account.label)],
            conversations: [Conversation(
                id: Conversation.ID("same-conversation"),
                kind: .space,
                title: account.label
            )],
            messages: [], startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        return AccountProvider(backend: FakeBackend(world: world))
    }

    func forgetCredentials(for account: AccountRecord) throws {
        if forgetFailures > 0 {
            forgetFailures -= 1
            throw ServiceFailure.internalFailure
        }
        forgotten.insert(account.id)
    }
}

struct ServiceHarness {
    let service: ChatService
    let providers: TestProviders
    let first: AccountRecord
    let second: AccountRecord
    let transport: InProcessChatTransport
    let directory: URL

    static func make() async throws -> ServiceHarness {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let registry = try SQLiteAccountRegistry(path: directory.appendingPathComponent("registry.sqlite")
            .path)
        let principal = ServicePrincipalID("owner")
        let first = AccountRecord(
            id: ConnectedAccountID("account-a"),
            principalID: principal,
            selfID: Member.ID("self-a"),
            label: "First",
            credentialGeneration: "one"
        )
        let second = AccountRecord(
            id: ConnectedAccountID("account-b"),
            principalID: principal,
            selfID: Member.ID("self-b"),
            label: "Second",
            credentialGeneration: "one"
        )
        try registry.save(first)
        try registry.save(second)
        let providers = TestProviders()
        let service = ChatService(
            registry: registry,
            storage: SQLiteServiceStorageFactory(directory: directory),
            providers: providers
        )
        try await service.restore()
        let transport = InProcessChatTransport(endpoint: service, context: ServiceSessionContext(
            principalID: principal, deviceID: ServiceDeviceID("mac"), sessionID: ClientSessionID("one"),
            accounts: [
                first.id,
                second.id
            ]
        ))
        _ = try await transport.negotiate(.current)
        let result = ServiceHarness(
            service: service,
            providers: providers,
            first: first,
            second: second,
            transport: transport,
            directory: directory
        )
        try await result.waitForAccounts()
        return result
    }

    func call<Payload: ServiceRequestPayload>(
        _ payload: Payload,
        account: ConnectedAccountID? = nil
    ) async throws -> Payload.Response {
        let request = try ServiceRequest(
            header: ServiceRequestHeader(requestID: ServiceRequestID(UUID().uuidString), accountID: account),
            payload: payload
        )
        return try await transport.exchange(request).value(for: Payload.self)
    }

    func waitForAccounts() async throws {
        for _ in 0 ..< 1000 {
            let accounts = try await call(ListAccounts())
            if accounts.count == 2, accounts.allSatisfy({ $0.connection == .connected }) {
                let firstPage = try await call(ReadEvents(cursor: nil, limit: 1), account: first.id)
                let secondPage = try await call(ReadEvents(cursor: nil, limit: 1), account: second.id)
                if firstPage.snapshot?
                    .contains(where: {
                        if case .conversationsChanged = $0 {
                            return true
                        }; return false
                    }) ==
                    true,
                    secondPage.snapshot?
                    .contains(where: {
                        if case .selfIdentified = $0 {
                            return true
                        }; return false
                    }) == true {
                    return
                }
            }
            await Task.yield()
        }
        Issue.record("The fixture service did not establish its account runtimes")
        throw ServiceFailure.deadlineExceeded
    }
}
