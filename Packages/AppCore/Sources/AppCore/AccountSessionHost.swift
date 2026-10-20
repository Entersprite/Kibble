import ChatAPI
import ChatKit
import Foundation

/// Native storage/session composition. Implementations receive verified API
/// summaries; shared orchestration never opens provider credentials.
@MainActor
public protocol AccountSessionHost: AnyObject {
    /// Recover orphaned replica cleanup before the first client session opens.
    func prepareForAccounts(_ accounts: [AccountSummary]) async throws
    /// Complete metadata also fences native notifications before async teardown.
    func updateAccountState(_ accounts: [AccountSummary])
    func makeEnvironment(for account: AccountSummary) async throws -> AppEnvironment
    func eraseReplica(for account: AccountSummary) async throws
}

public extension AccountSessionHost {
    func updateAccountState(_ accounts: [AccountSummary]) {}
}

struct AccountClientSession {
    let account: AccountSummary
    let environment: AppEnvironment
}

struct AccountClientIntent: Equatable {
    let revision: ServiceAccountRevision?
    let runtimeID: UUID?
    let isEnabled: Bool
    let isReady: Bool
    let isRemoving: Bool
    let authentication: String?
    let capabilities: ChatKit.Capabilities

    init(_ account: AccountSummary) {
        revision = account.revision
        runtimeID = account.runtimeID
        isEnabled = account.isEnabled
        isReady = account.isReady
        isRemoving = account.isRemoving
        authentication = account.authenticationState
        capabilities = account.capabilities
    }
}
