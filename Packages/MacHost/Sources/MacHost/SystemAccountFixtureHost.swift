import AppCore
import ChatAPI
import ChatKit
import ChatService
import ChatServiceStorage
import FixtureBackend
import Foundation
import InProcessChatTransport
import Observation
import ServiceClient

/// Isolated in-app composition for exercising the serialized account path.
/// It has no credential store, provider network or native notification delivery.
@MainActor
@Observable
public final class SystemAccountFixtureHost {
    public private(set) var workspace: AccountWorkspace?
    public private(set) var error: String?
    private var service: ChatService?
    private var registry: SQLiteAccountRegistry?
    private let providers = FixtureAccountProviders()
    private var active = false
    private var open = false
    private var minimized = false
    private var deviceActive = true
    private var starting = false
    private var generation = UUID()
    private let requestedDirectory: URL?

    public init(directory: URL? = nil) {
        requestedDirectory = directory
    }

    var activeRuntimeCount: Int {
        get async { await service?.activeRuntimeCount ?? 0 }
    }

    var retainedProviderCount: Int {
        get async { await providers.retainedCount }
    }

    public func dismissError() {
        error = nil
    }

    public func start() async {
        guard workspace == nil, !starting else { return }
        starting = true
        let generation = UUID()
        self.generation = generation
        defer { starting = false }
        var acquired: (any ServiceOwnershipLease)?
        do {
            let directory = try requestedDirectory ?? SystemLaunchServices.supportDirectory()
                .appendingPathComponent("MultiAccountFixture", isDirectory: true)
            let ownership = try FileServiceOwnership(file: directory.appendingPathComponent("service.lock"))
            let lease = try ownership.acquire()
            acquired = lease
            let instanceID = try LocalServiceIdentity.loadOrCreate(in: directory)
            let registry = try SQLiteAccountRegistry(path: directory.appendingPathComponent("registry.sqlite")
                .path)
            try seed(registry, directory: directory)
            let service = ChatService(
                registry: registry,
                storage: SQLiteServiceStorageFactory(directory: directory.appendingPathComponent("service")),
                providers: providers, ownership: GrantedFixtureOwnership(lease: lease), instanceID: instanceID
            )
            self.service = service
            self.registry = registry
            try await service.restore()
            guard generation == self.generation, !Task.isCancelled else {
                await service.shutdown()
                return
            }
            let workspace = makeWorkspace(service: service, directory: directory)
            workspace.setViewing(active: active, windowOpen: open, minimized: minimized)
            workspace.setDeviceActive(deviceActive)
            self.workspace = workspace
            workspace.start()
            error = nil
        } catch {
            guard generation == self.generation else { acquired?.release(); return }
            await service?.shutdown()
            service = nil
            registry = nil
            acquired?.release()
            self.error = "The account demo could not start. Close it and try again."
        }
    }

    private func makeWorkspace(service: ChatService, directory: URL) -> AccountWorkspace {
        let context = ServiceSessionContext(
            principalID: ServicePrincipalID("fixture-owner"), deviceID: ServiceDeviceID("fixture-device"),
            sessionID: ClientSessionID(UUID().uuidString), accounts: [], hasAllAccountAccess: true
        )
        let client = AccountClient(transport: InProcessChatTransport(endpoint: service, context: context))
        let host = FixtureAccountSessionHost(
            directory: directory.appendingPathComponent("clients"), client: client,
            transport: { account in
                InProcessChatTransport(endpoint: service, context: ServiceSessionContext(
                    principalID: context.principalID, deviceID: context.deviceID,
                    sessionID: ClientSessionID(UUID().uuidString), accounts: [account.id]
                ))
            }
        )
        let selection = directory.appendingPathComponent("selection.json")
        let selected = (try? Data(contentsOf: selection)).flatMap {
            try? ServiceCodec.decode(ConnectedAccountID.self, from: $0)
        }
        return AccountWorkspace(client: client, host: host, selected: selected) { id in
            try? ServiceCodec.encode(id).write(to: selection, options: .atomic)
        }
    }

    public func addAccount() async {
        guard let service, let registry else { return }
        do {
            let number = try registry.accounts().count + 1
            try await service.registerVerified(AccountRecord(
                id: ConnectedAccountID(UUID().uuidString), principalID: ServicePrincipalID("fixture-owner"),
                selfID: Member.ID("fixture-person-\(UUID().uuidString)"), label: "Demo \(number)",
                credentialGeneration: "fixture"
            ))
        } catch { self.error = "The demo account could not be added." }
    }

    public func setEnabled(_ enabled: Bool, account id: String) async {
        do {
            try await workspace?.setEnabled(enabled, account: ConnectedAccountID(id))
        } catch { self.error = "The account could not change state. Try again." }
    }

    public func removeAccount(_ id: String) async {
        do {
            try await workspace?.remove(ConnectedAccountID(id))
        } catch { self.error = "The account could not be removed. Try again." }
    }

    public func retryAccount(_ id: String) async {
        await workspace?.retry(ConnectedAccountID(id))
    }

    public func selectAccount(_ id: String) {
        workspace?.select(ConnectedAccountID(id))
    }

    public func simulateMessage(_ id: String, text: String = "A message for this account.") async {
        await providers.incoming(ConnectedAccountID(id), text: text)
    }

    public func setViewing(active: Bool? = nil, open: Bool? = nil, minimized: Bool? = nil) {
        if let active {
            self.active = active
        }
        if let open {
            self.open = open
        }
        if let minimized {
            self.minimized = minimized
        }
        workspace?.setViewing(active: self.active, windowOpen: self.open, minimized: self.minimized)
    }

    public func setDeviceActive(_ active: Bool) {
        deviceActive = active
        workspace?.setDeviceActive(active)
    }

    public func stop() async {
        generation = UUID()
        await workspace?.stop()
        workspace = nil
        await service?.shutdown()
        service = nil
        registry = nil
    }

    private func seed(_ registry: SQLiteAccountRegistry, directory: URL) throws {
        let marker = directory.appendingPathComponent("fixture.seeded")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        if try registry.accounts().isEmpty {
            for (id, identity, label) in [
                ("personal", Acme.alex, "Personal demo"), ("studio", Acme.maya, "Studio demo")
            ] {
                try registry.save(AccountRecord(
                    id: ConnectedAccountID(id), principalID: ServicePrincipalID("fixture-owner"),
                    selfID: identity, label: label, credentialGeneration: "fixture"
                ))
            }
        }
        try Data().write(to: marker, options: .atomic)
    }
}

private struct GrantedFixtureOwnership: ServiceOwnership {
    let lease: any ServiceOwnershipLease
    func acquire() -> any ServiceOwnershipLease {
        lease
    }
}

private actor FixtureAccountProviders: AccountProviderFactory {
    private var backends: [ConnectedAccountID: WeakFixtureBackend] = [:]
    var retainedCount: Int {
        backends.values.filter { $0.backend != nil }.count
    }

    func makeProvider(for account: AccountRecord) -> AccountProvider {
        var world = FixtureWorld.acme
        world.me = account.selfID
        if !world.members.contains(where: { $0.id == account.selfID }) {
            world.members.append(Member(id: account.selfID, kind: .human, displayName: account.label))
        }
        let backend = FakeBackend(world: world, directory: FixtureWorld.acmeDirectory)
        backends[account.id] = WeakFixtureBackend(backend)
        let now = world.startedAt
        return AccountProvider(backend: backend, now: { now })
    }

    func forgetCredentials(for account: AccountRecord) {
        backends[account.id] = nil
    }

    func incoming(_ account: ConnectedAccountID, text: String) async {
        try? await backends[account]?.backend?.apply(.incomingMessage(
            conversation: Acme.priceEngine, from: Acme.dan, text: text, thread: nil
        ))
    }
}

private final class WeakFixtureBackend {
    weak var backend: FakeBackend?
    init(_ backend: FakeBackend) {
        self.backend = backend
    }
}
