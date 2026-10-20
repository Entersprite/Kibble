import ChatAPI
import ChatKit
import ChatService
import ChatServiceStorage
import FixtureBackend
import Foundation

actor NotificationTestHost: ServiceNotificationHost {
    nonisolated let deviceID = ServiceDeviceID("notification-device")
    private(set) var frames: [HostNotificationFrame] = []
    var states: [ConnectedAccountID: NotificationDeviceState] = [:]
    func state(account: ConnectedAccountID) -> NotificationDeviceState {
        states[account] ?? .init()
    }

    func setState(_ state: NotificationDeviceState, account: ConnectedAccountID) {
        states[account] = state
    }

    func deliver(_ bytes: Data) throws {
        try frames.append(ServiceCodec.decode(
            HostNotificationFrame.self,
            from: bytes
        ))
    }

    var posts: [HostNotificationFrame] {
        frames.filter { $0.operation == "post" }
    }
}

actor NotificationTestProviders: AccountProviderFactory {
    private var backends: [ConnectedAccountID: FakeBackend] = [:]
    func makeProvider(for account: AccountRecord) -> AccountProvider {
        let world = FixtureWorld(
            me: account.selfID, members: [
                Member(id: account.selfID, kind: .human, displayName: "Self"),
                Member(id: .init("peer"), kind: .human, displayName: "Peer")
            ], conversations: [Conversation(id: .init("same"), kind: .space, title: "Room")],
            messages: [], startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let backend = FakeBackend(world: world)
        backends[account.id] = backend
        return AccountProvider(backend: backend)
    }

    func forgetCredentials(for _: AccountRecord) {}
    func incoming(_ account: ConnectedAccountID, count: Int = 1) async throws {
        guard let backend = backends[account] else { throw ServiceFailure.accountNotFound }
        for _ in 0 ..< count {
            try await backend.apply(.incomingMessage(
                conversation: .init("same"),
                from: .init("peer"),
                text: "Fresh arrival",
                thread: nil
            ))
        }
    }
}

struct NotificationHarness {
    let directory: URL
    let registry: SQLiteAccountRegistry
    let service: ChatService
    let providers: NotificationTestProviders
    let host: NotificationTestHost
    let accounts: [AccountRecord]

    static func make() async throws -> Self {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let registry = try SQLiteAccountRegistry(path: directory.appendingPathComponent("registry.sqlite")
            .path)
        let accounts = ["first", "second"].map {
            AccountRecord(
                id: .init($0),
                principalID: .init("owner"),
                selfID: .init("self-\($0)"),
                label: $0,
                credentialGeneration: "fixture"
            )
        }
        for record in accounts {
            try registry.save(record)
        }
        let host = NotificationTestHost()
        let providers = NotificationTestProviders()
        let service = ChatService(
            registry: registry,
            storage: SQLiteServiceStorageFactory(directory: directory),
            providers: providers,
            notificationHost: host
        )
        try await service.restore()
        return Self(
            directory: directory,
            registry: registry,
            service: service,
            providers: providers,
            host: host,
            accounts: accounts
        )
    }
}
