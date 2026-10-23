import ChatAPI
import ChatKit
import ChatServiceStorage
import FixtureBackend
import Foundation
import InProcessChatTransport
import ServiceClient
import Testing
@testable import ChatService

actor CallProviders: AccountProviderFactory {
    private var sources: [ConnectedAccountID: [ServiceDeviceID: FixtureAudioCallService]] = [:]
    private var gates: [ConnectedAccountID: CallMembershipGate] = [:]
    private let heldMembership: Bool

    init(heldMembership: Bool = false) {
        self.heldMembership = heldMembership
    }

    func makeProvider(for account: AccountRecord) async -> AccountProvider {
        let world = FixtureWorld(
            me: account.selfID, members: [
                Member(id: account.selfID, kind: .human, displayName: "Self"),
                Member(id: .init("peer"), kind: .human, displayName: "Verified peer")
            ], conversations: [Conversation(
                id: .init("same"), kind: .directMessage, title: "Peer", members: [
                    account.selfID,
                    .init("peer")
                ]
            ), Conversation(id: .init("group"), kind: .groupDirectMessage, title: "Test group", members: [
                account.selfID, .init("peer"), .init("third")
            ])], messages: [], startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let calls = await MainActor.run {
            [
                ServiceDeviceID("one"): FixtureAudioCallService(world: world),
                ServiceDeviceID("two"): FixtureAudioCallService(world: world)
            ]
        }
        sources[account.id] = calls
        let backend = FakeBackend(world: world)
        if heldMembership {
            let gate = CallMembershipGate(inner: backend)
            gates[account.id] = gate
            return AccountProvider(backend: gate, calls: calls)
        }
        return AccountProvider(backend: backend, calls: calls)
    }

    func forgetCredentials(for _: AccountRecord) {}
    func source(_ account: ConnectedAccountID, device: ServiceDeviceID) -> FixtureAudioCallService? {
        sources[account]?[device]
    }

    func gate(_ account: ConnectedAccountID) -> CallMembershipGate? {
        gates[account]
    }
}

struct CallHarness {
    let service: ChatService
    let providers: CallProviders
    let accounts: [AccountRecord]

    static func make(heldMembership: Bool = false) async throws -> Self {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let registry = try SQLiteAccountRegistry(path: directory.appendingPathComponent("registry.sqlite")
            .path)
        let accounts = ["first", "second"].map { AccountRecord(
            id: .init($0), principalID: .init("owner"), selfID: .init("self-\($0)"), label: $0,
            credentialGeneration: "fixture"
        ) }
        for account in accounts {
            try registry.save(account)
        }
        let providers = CallProviders(heldMembership: heldMembership)
        let service = ChatService(
            registry: registry, storage: SQLiteServiceStorageFactory(directory: directory),
            providers: providers
        )
        try await service.restore()
        let harness = Self(service: service, providers: providers, accounts: accounts)
        try await eventually {
            let summaries = try await harness.client().accounts()
            guard summaries.count == 2, summaries.allSatisfy(\.isReady) else { return false }
            for account in accounts {
                let state = try await harness.read(account)
                if !state.isListening || state.recipients.isEmpty {
                    return false
                }
                guard let runtime = await service.runtimes[account.id] else { return false }
                let refresh = await runtime.worldRefresh
                let storage = await runtime.storage
                guard refresh == nil, try storage.conversation(.init("same")) != nil else { return false }
            }
            return true
        }
        return harness
    }

    func client(device: String = "one", session: String = "client") -> AccountClient {
        AccountClient(transport: InProcessChatTransport(endpoint: service, context: ServiceSessionContext(
            principalID: .init("owner"), deviceID: .init(device), sessionID: .init(session),
            accounts: Set(accounts.map(\.id))
        )))
    }

    func read(_ account: AccountRecord, device: String = "one") async throws -> ServiceCallState {
        try await client(device: device).call(
            ReadCallState(waitMilliseconds: 0), account: account.id, revision: account.currentRevision
        )
    }
}

@MainActor
func callEventually(_ condition: @MainActor () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        if try await condition() {
            return
        }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw ServiceFailure.deadlineExceeded
}
