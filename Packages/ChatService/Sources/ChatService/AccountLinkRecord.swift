import ChatAPI
import ChatKit
import Foundation

/// Durable cross-vault intent. Only the injected custody port handles secrets.
public struct AccountLinkRecord: Codable, Hashable, Sendable {
    public let id: AccountLinkID
    public let operationID: ServiceOperationID
    public let principalID: ServicePrincipalID
    public let deviceID: ServiceDeviceID
    public let targetAccountID: ConnectedAccountID?
    public let accountID: ConnectedAccountID
    public let generation: String
    public let previousGeneration: String?
    public let removalRevision: String?
    public let expiresAt: Date
    public var resolvedAccountID: ConnectedAccountID?
    public var phase: String
    public var selfID: Member.ID?
    public var label: String

    public init(
        id: AccountLinkID, operationID: ServiceOperationID, principalID: ServicePrincipalID,
        deviceID: ServiceDeviceID, targetAccountID: ConnectedAccountID?,
        accountID: ConnectedAccountID, generation: String, previousGeneration: String?,
        expiresAt: Date, phase: String = "pendingCapture", selfID: Member.ID? = nil,
        label: String = "Account",
        removalRevision: String? = nil
    ) {
        self.id = id
        self.operationID = operationID
        self.principalID = principalID
        self.deviceID = deviceID
        self.targetAccountID = targetAccountID
        self.accountID = accountID
        self.generation = generation
        self.previousGeneration = previousGeneration
        self.removalRevision = removalRevision
        self.expiresAt = expiresAt
        self.phase = phase
        self.selfID = selfID
        self.label = label
    }

    public var summary: AccountLinkSummary {
        .init(id: id, accountID: resolvedAccountID ?? accountID, phase: phase)
    }
}

public protocol AccountLinkRegistry: AccountRegistry {
    func links() throws -> [AccountLinkRecord]
    func saveLink(_ link: AccountLinkRecord) throws
    func removalRevision() throws -> String
    func validateLinkAdmission(_ link: AccountLinkRecord) throws
    /// Publishes the account binding and committed intent in one transaction.
    func commitLink(_ link: AccountLinkRecord, account: AccountRecord) throws
}

public struct VerifiedLinkIdentity: Sendable {
    public let selfID: Member.ID
    public let label: String
    public init(selfID: Member.ID, label: String) {
        self.selfID = selfID; self.label = label
    }
}

/// Trusted host operations. The host verifies identity again if it has to
/// reconstruct a sealed candidate; client-supplied identity never enters here.
public protocol AccountLinkCustody: Sendable {
    func verify(_ link: AccountLinkRecord) async throws -> VerifiedLinkIdentity
    func install(_ link: AccountLinkRecord) async throws
    func discardStaging(_ link: AccountLinkRecord) async throws
    func eraseGeneration(account: ConnectedAccountID, generation: String) async throws
}
