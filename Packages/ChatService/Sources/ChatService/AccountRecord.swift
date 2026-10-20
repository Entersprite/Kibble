import ChatAPI
import ChatKit
import Foundation

/// Credential bytes belong to a host vault, never this registry.
public struct AccountRecord: Codable, Hashable, Sendable {
    public let id: ConnectedAccountID
    public let principalID: ServicePrincipalID
    public let selfID: Member.ID
    public var label: String
    public var isEnabled: Bool
    public var credentialGeneration: String
    /// Client request fencing, separate from the host's secret slot reference.
    public var authenticationState: String?
    public var revision: ServiceAccountRevision?
    public var currentRevision: ServiceAccountRevision {
        revision ?? ServiceAccountRevision("initial:\(id.rawValue)")
    }

    /// A removal intent survives interruption of vault/storage cleanup.
    public var isRemoving: Bool
    /// Part of the removal intent: the removal also forgets the settings kept
    /// for this identity, even when it resumes after an interruption.
    public var forgetsSettings: Bool?
    /// The last own identity the provider reported. Display metadata, kept
    /// across disable and sign-in loss so the account can still be shown.
    public var profile: AccountProfile?
    /// Where the account is listed; accounts are added at the end. Records
    /// saved before ordering existed have none and list after the rest.
    public var position: Int?

    public init(
        id: ConnectedAccountID, principalID: ServicePrincipalID, selfID: Member.ID,
        label: String, isEnabled: Bool = true, credentialGeneration: String,
        isRemoving: Bool = false,
        revision: ServiceAccountRevision? = ServiceAccountRevision(UUID().uuidString),
        authenticationState: String? = nil, profile: AccountProfile? = nil, position: Int? = nil
    ) {
        self.id = id
        self.principalID = principalID
        self.selfID = selfID
        self.label = label
        self.isEnabled = isEnabled
        self.credentialGeneration = credentialGeneration
        self.authenticationState = authenticationState
        self.revision = revision
        self.isRemoving = isRemoving
        self.profile = profile
        self.position = position
    }
}

public protocol AccountRegistry: Sendable {
    func accounts() throws -> [AccountRecord]
    func save(_ account: AccountRecord) throws
    func remove(_ account: ConnectedAccountID) throws
}

public protocol ServiceAccountStorage: Sendable {
    func append(_ event: ChatEvent, live: Bool) throws -> ServiceCursor
    func readEvents(after cursor: ServiceCursor?, limit: Int) throws -> ServiceEventPage
    func conversations() throws -> [Conversation]
    func conversation(_ id: Conversation.ID) throws -> Conversation?
    func checkpoint() throws -> ServiceCursor
    func recentHistory(in conversation: Conversation.ID, limit: Int) throws -> [Message]
    func operation(_ id: ServiceOperationID) throws -> ServiceOperation?
    /// Atomically reserves a new operation, or returns the existing identical one.
    func reserve(_ id: ServiceOperationID, request: ServiceRequest) throws -> ServiceOperation
    func finish(_ operation: ServiceOperation) throws
}

public protocol ServiceStorageFactory: Sendable {
    func open(_ account: ConnectedAccountID) throws -> any ServiceAccountStorage
    func erase(_ account: ConnectedAccountID) throws
}

/// The trusted host verifies identity before constructing this record/provider pair.
/// Future remote clients cannot submit a provider object or a credential reference.
public struct AccountProvider: Sendable {
    public let backend: any ChatBackend
    public let now: @Sendable () -> Date
    /// Trusted host media bindings. Clients cannot submit a native service.
    public let calls: [ServiceDeviceID: any AudioCallService]

    public init(
        backend: any ChatBackend, calls: [ServiceDeviceID: any AudioCallService] = [:],
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.backend = backend
        self.calls = calls
        self.now = now
    }

    func discard() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await backend.disconnect() }
            for source in calls.values {
                group.addTask { await source.stop() }
            }
        }
    }
}

public protocol AccountProviderFactory: Sendable {
    func makeProvider(for account: AccountRecord) async throws -> AccountProvider
    func forgetCredentials(for account: AccountRecord) async throws
}
