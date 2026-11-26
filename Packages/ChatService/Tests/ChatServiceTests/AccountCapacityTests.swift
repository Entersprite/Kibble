import ChatAPI
import ChatKit
import ChatServiceStorage
import FixtureBackend
import Foundation
import InProcessChatTransport
import Testing
@testable import ChatService

@Suite(.timeLimit(.minutes(1)))
struct AccountCapacityTests {
    @Test(arguments: [1, 2, 5])
    func disabledRegistryEntriesDoNotOpenProvidersOrStoresAndChurnReleasesThem(active: Int) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let registry = try SQLiteAccountRegistry(path: folder.appendingPathComponent("registry.sqlite").path)
        let accounts = (0 ..< 105).map { index in AccountRecord(
            id: .init("account-\(index)"), principalID: .init("owner"), selfID: .init("self-\(index)"),
            label: "Account", isEnabled: index < active, credentialGeneration: "fixture"
        ) }
        for account in accounts {
            try registry.save(account)
        }
        let providers = CapacityProviders()
        let storage = CapacityStorage(directory: folder.appendingPathComponent("service"))
        let service = ChatService(registry: registry, storage: storage, providers: providers)
        let clock = ContinuousClock.now
        try await service.restore()
        let transport = InProcessChatTransport(endpoint: service, context: .init(
            principalID: .init("owner"), deviceID: .init("device"), sessionID: .init("client"),
            accounts: [], hasAllAccountAccess: true
        ))
        _ = try await transport.negotiate(.current)
        try await capacityEventually { await providers.alive == active }
        #expect(await service.activeRuntimeCount == active)
        #expect(storage.alive == active)
        #expect(storage.opened == active)
        let initialStarts = await providers.started
        #expect(initialStarts == active)
        print(
            "Account capacity: \(active) active/\(105 - active) disabled; "
                + "startup \(clock.duration(to: .now)); "
                + "providers/stores \(active)/\(storage.alive)"
        )
        for _ in 0 ..< 3 {
            for account in accounts.prefix(active) {
                try await set(false, account: account, transport: transport)
            }
            try await capacityEventually { await providers.alive == 0 && storage.alive == 0 }
            #expect(await service.activeRuntimeCount == 0)
            for account in accounts.prefix(active) {
                try await set(true, account: account, transport: transport)
            }
            try await capacityEventually { await providers.alive == active && storage.alive == active }
        }
        await service.shutdown()
        #expect(await service.activeRuntimeCount == 0)
        #expect(await providers.alive == 0)
        #expect(storage.alive == 0)
        #expect(await providers.started == active * 4)
    }

    private func set(
        _ enabled: Bool,
        account: AccountRecord,
        transport: InProcessChatTransport
    ) async throws {
        let request = try ServiceRequest(
            header: .init(
                requestID: .init(UUID().uuidString),
                accountID: account.id,
                accountRevision: account.currentRevision
            ),
            payload: SetAccountEnabled(enabled: enabled)
        )
        _ = try await transport.exchange(request).value(for: SetAccountEnabled.self)
    }
}

private actor CapacityProviders: AccountProviderFactory {
    private var backends: [WeakCapacityBackend] = []
    private(set) var started = 0
    var alive: Int {
        backends.filter { $0.value != nil }.count
    }

    func makeProvider(for account: AccountRecord) -> AccountProvider {
        started += 1
        var world = FixtureWorld.acme
        world.me = account.selfID
        let backend = FakeBackend(world: world)
        backends.append(WeakCapacityBackend(backend))
        return AccountProvider(backend: backend)
    }

    func forgetCredentials(for _: AccountRecord) {}
}

private final class WeakCapacityBackend {
    weak var value: FakeBackend?
    init(_ value: FakeBackend) {
        self.value = value
    }
}

private final class CapacityStorage: ServiceStorageFactory, @unchecked Sendable {
    private let lock = NSLock()
    private let factory: SQLiteServiceStorageFactory
    private var stores: [WeakCapacityStore] = []
    private var count = 0
    var alive: Int {
        lock.withLock { stores.filter { $0.value != nil }.count }
    }

    var opened: Int {
        lock.withLock { count }
    }

    init(directory: URL) {
        factory = SQLiteServiceStorageFactory(directory: directory)
    }

    func open(_ account: ConnectedAccountID) throws -> any ServiceAccountStorage {
        let store = try factory.open(account)
        lock.withLock { stores.append(WeakCapacityStore(store as? SQLiteAccountStorage)); count += 1 }
        return store
    }

    func erase(_ account: ConnectedAccountID) throws {
        try factory.erase(account)
    }
}

private final class WeakCapacityStore {
    weak var value: SQLiteAccountStorage?
    init(_ value: SQLiteAccountStorage?) {
        self.value = value
    }
}
