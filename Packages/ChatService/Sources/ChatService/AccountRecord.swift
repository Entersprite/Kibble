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

    public init(
        id: ConnectedAccountID, principalID: ServicePrincipalID, selfID: Member.ID,
        label: String, isEnabled: Bool = true, credentialGeneration: String,
        isRemoving: Bool = false,
        revision: ServiceAccountRevision? = ServiceAccountRevision(UUID().uuidString),
        authenticationState: String? = nil
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

    public init(backend: any ChatBackend, now: @escaping @Sendable () -> Date = { Date() }) {
        self.backend = backend
        self.now = now
    }
}

public protocol AccountProviderFactory: Sendable {
    func makeProvider(for account: AccountRecord) async throws -> AccountProvider
    func forgetCredentials(for account: AccountRecord) async throws
}
