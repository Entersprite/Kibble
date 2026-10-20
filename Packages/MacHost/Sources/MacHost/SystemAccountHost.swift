import AppCore
import ChatAPI
import ChatKit
import ChatService
import ChatServiceStorage
import FixtureBackend
import Foundation
import InProcessChatTransport
import LocalBridgeBackend
import Observation
import ServiceClient

/// Process-owned embedded account service and its serialized client workspace.
/// Fixture installations use a separate namespace and never open provider credentials.
@MainActor
@Observable
public final class SystemAccountHost {
    public private(set) var workspace: AccountWorkspace?
    public internal(set) var error: String?
    /// The account a reconnect was refused for because a different Google
    /// account signed in. Nothing was installed; the account still waits.
    public internal(set) var refusedSignIn: String?
    var service: ChatService?
    private var registry: SQLiteAccountRegistry?
    private let providers = FixtureAccountProviders()
    public let usesGoogleAccounts: Bool
    let callBindings = NativeAccountCallBindings()
    var diagnostics: DiagnosticReportStore?
    var custody: LocalAccountCustody?
    var context: ServiceSessionContext?
    private var deviceID = ServiceDeviceID("fixture-device")
    private var active = false
    private var open = false
    private var minimized = false
    private var deviceActive = true
    private var starting = false
    private var startupTask: Task<Void, Never>?
    var captureWindow: AccountSignInWindow?
    var generation = UUID()
    private let requestedDirectory: URL?
    private let notificationCenter: (any AccountNotificationDelivering)?
    private var notificationRouter: AccountNotificationRouter?
    private var notificationActions: ServiceNotificationActions?
    var clients: ServiceAccountSessionHost?
    public private(set) var deviceNotificationPause: DeviceNotificationPause?

    public init(
        directory: URL? = nil, notifications: (any AccountNotificationDelivering)? = nil,
        usesGoogleAccounts: Bool = false
    ) {
        self.usesGoogleAccounts = usesGoogleAccounts
        requestedDirectory = directory
        notificationCenter = notifications
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

    public func dismissRefusedSignIn() {
        refusedSignIn = nil
    }

    public func start() async {
        if let startupTask {
            await startupTask.value; return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await runStart()
        }
        startupTask = task
        await task.value
        startupTask = nil
    }

    private func runStart() async {
        guard workspace == nil, !starting else { return }
        starting = true
        let generation = UUID()
        self.generation = generation
        defer { starting = false }
        var acquired: (any ServiceOwnershipLease)?
        do {
            let directory = try requestedDirectory ?? SystemLaunchServices.supportDirectory()
                .appendingPathComponent(
                    usesGoogleAccounts ? "Accounts" : "MultiAccountFixture",
                    isDirectory: true
                )
            let ownership = try FileServiceOwnership(file: directory.appendingPathComponent("service.lock"))
            let lease = try ownership.acquire()
            acquired = lease
            let instanceID = try LocalServiceIdentity.loadOrCreate(in: directory)
            let registry = try SQLiteAccountRegistry(path: directory.appendingPathComponent("registry.sqlite")
                .path)
            let accountProviders = try await makeProviders(
                registry,
                directory: directory,
                instanceID: instanceID
            )
            try Task.checkCancellation()
            let service = makeService(
                registry: registry, providers: accountProviders, directory: directory,
                lease: lease, instanceID: instanceID
            )
            self.service = service
            self.registry = registry
            try await service.restore()
            guard generation == self.generation, !Task.isCancelled else {
                await service.shutdown()
                return
            }
            let workspace = try await makeWorkspace(service: service, directory: directory)
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
            reportStartFailure()
        }
    }

    private func reportStartFailure() {
        error = usesGoogleAccounts
            ? "Accounts could not start. Your login and data are preserved. "
            + "Check the network and Keychain, then retry."
            : "The account demo could not start. Close it and try again."
    }

    private func makeService(
        registry: SQLiteAccountRegistry, providers: any AccountProviderFactory, directory: URL,
        lease: any ServiceOwnershipLease, instanceID: ServiceInstanceID
    ) -> ChatService {
        let notificationHost = makeNotificationHost(service: instanceID, directory: directory)
        return ChatService(
            registry: registry,
            storage: SQLiteServiceStorageFactory(directory: directory.appendingPathComponent("service")),
            providers: providers,
            transferFiles: DirectoryTransferStorageFactory(directory: directory
                .appendingPathComponent("transfers")),
            linkCustody: custody, ownership: GrantedFixtureOwnership(lease: lease),
            notificationHost: notificationHost,
            instanceID: instanceID
        )
    }

    private func makeProviders(
        _ registry: SQLiteAccountRegistry, directory: URL, instanceID: ServiceInstanceID
    ) async throws -> any AccountProviderFactory {
        let accountProviders: any AccountProviderFactory
        if usesGoogleAccounts {
            deviceID = try ServiceDeviceID(FileNotificationSettingsStore(
                directory: SystemLaunchServices.supportDirectory()
            ).deviceID())
            let custody = try LocalAccountCustody(
                storage: KeychainSecretStorage(service: KeychainCredentialStore.defaultService),
                instanceID: instanceID
            )
            self.custody = custody
            try await migrateLegacy(
                into: directory,
                instance: instanceID,
                registry: registry,
                custody: custody
            )
            accountProviders = NativeAccountProviders(
                custody: custody, directory: directory.appendingPathComponent("providers"),
                device: deviceID, bindings: callBindings, diagnostics: diagnostics
            )
        } else {
            try seed(registry, directory: directory)
            accountProviders = providers
        }
        return accountProviders
    }

    private func makeWorkspace(service: ChatService, directory: URL) async throws -> AccountWorkspace {
        let context = ServiceSessionContext(
            principalID: principalID, deviceID: deviceID,
            sessionID: ClientSessionID(UUID().uuidString), accounts: [], hasAllAccountAccess: true,
            canLinkAccounts: usesGoogleAccounts
        )
        self.context = context
        let client = AccountClient(transport: InProcessChatTransport(endpoint: service, context: context))
        let info = try await client.serviceInfo()
        let router = notificationCenter
            .map { AccountNotificationRouter(service: info.instanceID, center: $0, clientArrivals: false) }
        notificationRouter = router
        let actions = ServiceNotificationActions(
            service: info.instanceID,
            client: client,
            device: deviceID.rawValue
        )
        notificationActions = actions
        actions.onFailure = { [weak self] in self?.error = "The notification action could not complete." }
        router?.onBackgroundResponse = { [weak actions] in actions?.handle($0) ?? false }
        router?.start()
        let devicePause = deviceNotificationPause
        let host = ServiceAccountSessionHost(
            directory: directory.appendingPathComponent("clients"), client: client,
            transport: { account in
                InProcessChatTransport(endpoint: service, context: ServiceSessionContext(
                    principalID: context.principalID, deviceID: context.deviceID,
                    sessionID: ClientSessionID(UUID().uuidString), accounts: [account.id]
                ))
            }, notifications: router, devicePause: devicePause, fixture: !usesGoogleAccounts,
            deviceID: deviceID.rawValue
        )
        clients = host
        let selection = directory.appendingPathComponent("selection.json")
        let selected = (try? Data(contentsOf: selection)).flatMap {
            try? ServiceCodec.decode(ConnectedAccountID.self, from: $0)
        }
        let workspace = AccountWorkspace(client: client, host: host, selected: selected) { id in
            try? ServiceCodec.encode(id).write(to: selection, options: .atomic)
        }
        router?.onOpenAccount = { [weak workspace] in workspace?.showAccount($0) }
        return workspace
    }
}

public extension SystemAccountHost {
    func addAccount() async {
        if usesGoogleAccounts {
            await beginSignIn()
            return
        }
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

    func setEnabled(_ enabled: Bool, account id: String) async {
        do {
            try await workspace?.setEnabled(enabled, account: ConnectedAccountID(id))
        } catch { self.error = "The account could not change state. Try again." }
    }

    func retryAccount(_ id: String) async {
        if usesGoogleAccounts,
           workspace?.accounts.first(where: { $0.id.rawValue == id })?.authenticationState == "required" {
            await beginSignIn(replacing: ConnectedAccountID(id))
            return
        }
        await workspace?.retry(ConnectedAccountID(id))
    }

    func selectAccount(_ id: String) {
        workspace?.select(ConnectedAccountID(id))
    }

    func simulateMessage(_ id: String, text: String = "A message for this account.") async {
        do {
            try await clients?.synchronizeReplica(ConnectedAccountID(id))
            await providers.incoming(ConnectedAccountID(id), text: text)
        } catch { self.error = "The demo account is still catching up. Try again." }
    }

    private func makeNotificationHost(
        service: ServiceInstanceID, directory: URL
    ) -> LocalServiceNotificationHost? {
        deviceNotificationPause = DeviceNotificationPause(store: FileDeviceNotificationPauseStore(
            file: directory.appendingPathComponent("device-pause.json")
        ))
        return notificationCenter.map { center in
            LocalServiceNotificationHost(
                service: service, device: deviceID, center: center,
                directory: directory.appendingPathComponent("notification-deliveries"),
                label: { [weak self] account in self?.notificationLabel(account) },
                visibility: { [weak self] account in self?.notificationState(account) ?? .init(paused: true) }
            )
        }
    }

    /// The account's label on its alerts while several are connected.
    private func notificationLabel(_ account: ConnectedAccountID) -> String? {
        guard let workspace, workspace.accounts.count > 1 else { return nil }
        return workspace.accountLabels[account]
    }

    private func notificationState(_ account: ConnectedAccountID) -> NotificationDeviceState {
        let paused = deviceNotificationPause?.isActive ?? true
        guard workspace?.selectedID == account,
              case let .running(model)? = workspace?.selectedEnvironment?.phase, model.isActive else {
            return NotificationDeviceState(paused: paused)
        }
        return NotificationDeviceState(
            conversation: model.selected,
            thread: model.isThreadPanelShown ? model.threads.openThread : nil, paused: paused
        )
    }

    func setViewing(active: Bool? = nil, open: Bool? = nil, minimized: Bool? = nil) {
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

    func setDeviceActive(_ active: Bool) {
        deviceActive = active
        workspace?.setDeviceActive(active)
    }

    func stop() async {
        generation = UUID()
        startupTask?.cancel()
        await startupTask?.value
        startupTask = nil
        captureWindow?.close()
        captureWindow = nil
        try? await workspace?.cancelCapture()
        generation = UUID()
        await notificationRouter?.stop()
        notificationRouter = nil
        await notificationActions?.stop()
        notificationActions = nil
        await workspace?.stop()
        workspace = nil
        clients = nil
        await service?.shutdown()
        service = nil
        registry = nil
        custody = nil
        context = nil
    }

    private var principalID: ServicePrincipalID {
        ServicePrincipalID(usesGoogleAccounts ? "local-owner" : "fixture-owner")
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

/// Compatibility name for the isolated fixture initializer.
public typealias SystemAccountFixtureHost = SystemAccountHost
