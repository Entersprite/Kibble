import Foundation

/// Complete control-plane state. A newer snapshot replaces an older one;
/// durable chat events use the separate checkpointed event stream.
public struct AccountStateSnapshot: Codable, Hashable, Sendable {
    public let accounts: [AccountSummary]
    public let pendingLinks: [AccountLinkSummary]

    public init(accounts: [AccountSummary], pendingLinks: [AccountLinkSummary]) {
        self.accounts = accounts
        self.pendingLinks = pendingLinks
    }
}

public struct WatchAccounts: ServiceRequestPayload {
    public typealias Response = AccountStateSnapshot
    public static let operation = "watchAccounts"
    public static let requiresAccount = false
    public init() {}
}

public struct ListAccountLinks: ServiceRequestPayload {
    public typealias Response = [AccountLinkSummary]
    public static let operation = "listAccountLinks"
    public static let requiresAccount = false
    public init() {}
}

public protocol ServiceAccountStateEndpoint: ServiceEndpoint {
    func accountStates(_ request: Data, context: ServiceSessionContext) async throws
        -> AsyncThrowingStream<Data, any Error>
}

public protocol ServiceAccountStateTransport: ServiceTransport {
    func accountStates(_ request: ServiceRequest) async throws
        -> AsyncThrowingStream<AccountStateSnapshot, any Error>
}
