import ChatAPI
import ChatKit

/// Native storage/session composition. Implementations receive verified API
/// summaries; shared orchestration never opens provider credentials.
@MainActor
public protocol AccountSessionHost: AnyObject {
    /// Recover orphaned replica cleanup before the first client session opens.
    func prepareForAccounts(_ accounts: [AccountSummary]) async throws
    func makeEnvironment(for account: AccountSummary) async throws -> AppEnvironment
    func eraseReplica(for account: AccountSummary) async throws
}

struct AccountClientSession {
    let account: AccountSummary
    let environment: AppEnvironment
}

struct AccountClientIntent: Equatable {
    let revision: ServiceAccountRevision?
    let isEnabled: Bool
    let isReady: Bool
    let isRemoving: Bool
    let authentication: String?
    let capabilities: ChatKit.Capabilities

    init(_ account: AccountSummary) {
        revision = account.revision
        isEnabled = account.isEnabled
        isReady = account.isReady
        isRemoving = account.isRemoving
        authentication = account.authenticationState
        capabilities = account.capabilities
    }
}
