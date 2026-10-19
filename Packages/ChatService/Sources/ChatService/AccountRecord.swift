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
    /// A removal intent survives interruption of vault/storage cleanup.
    public var isRemoving: Bool

    public init(
        id: ConnectedAccountID, principalID: ServicePrincipalID, selfID: Member.ID,
        label: String, isEnabled: Bool = true, credentialGeneration: String,
        isRemoving: Bool = false
    ) {
        self.id = id
        self.principalID = principalID
        self.selfID = selfID
        self.label = label
        self.isEnabled = isEnabled
        self.credentialGeneration = credentialGeneration
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
    func operation(_ id: ServiceOperationID) throws -> ServiceOperation?
    /// Atomically reserves a new operation, or returns the existing identical one.
    func reserve(_ id: ServiceOperationID, request: ServiceRequest) throws -> ServiceOperation
    func finish(_ operation: ServiceOperation) throws
    func policy() throws -> AccountPolicy
    func setPolicy(_ settings: NotificationSettings, expectedRevision: String) throws -> AccountPolicy
}

public protocol ServiceStorageFactory: Sendable {
    func open(_ account: ConnectedAccountID) throws -> any ServiceAccountStorage
    func erase(_ account: ConnectedAccountID) throws
}

/// The trusted host verifies identity before constructing this record/provider pair.
/// Future remote clients cannot submit a provider object or a credential reference.
public struct AccountProvider: Sendable {
    public let backend: any ChatBackend

    public init(backend: any ChatBackend) {
        self.backend = backend
    }
}

public protocol AccountProviderFactory: Sendable {
    func makeProvider(for account: AccountRecord) async throws -> AccountProvider
    func forgetCredentials(for account: AccountRecord) async throws
}
