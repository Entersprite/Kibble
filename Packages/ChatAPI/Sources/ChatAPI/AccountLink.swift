import Foundation

/// Link handles identify staged work, never a credential or an account grant.
public struct AccountLinkSummary: Codable, Hashable, Sendable {
    public let id: AccountLinkID
    public let accountID: ConnectedAccountID
    public let phase: String

    public init(id: AccountLinkID, accountID: ConnectedAccountID, phase: String) {
        self.id = id
        self.accountID = accountID
        self.phase = phase
    }
}

public struct BeginAccountLink: ServiceRequestPayload {
    public typealias Response = AccountLinkSummary
    public static let operation = "beginAccountLink"
    public static let requiresAccount = false
    public let operationID: ServiceOperationID
    public let targetAccountID: ConnectedAccountID?

    public init(operationID: ServiceOperationID, targetAccountID: ConnectedAccountID? = nil) {
        self.operationID = operationID
        self.targetAccountID = targetAccountID
    }
}

public struct GetAccountLink: ServiceRequestPayload {
    public typealias Response = AccountLinkSummary
    public static let operation = "getAccountLink"
    public static let requiresAccount = false
    public let linkID: AccountLinkID
    public init(linkID: AccountLinkID) {
        self.linkID = linkID
    }
}

public struct CompleteAccountLink: ServiceRequestPayload {
    public typealias Response = AccountLinkSummary
    public static let operation = "completeAccountLink"
    public static let requiresAccount = false
    public let linkID: AccountLinkID
    public init(linkID: AccountLinkID) {
        self.linkID = linkID
    }
}

public struct CancelAccountLink: ServiceRequestPayload {
    public typealias Response = AccountLinkSummary
    public static let operation = "cancelAccountLink"
    public static let requiresAccount = false
    public let linkID: AccountLinkID
    public init(linkID: AccountLinkID) {
        self.linkID = linkID
    }
}
