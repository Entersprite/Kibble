import ChatAPI
import ChatKit
import Foundation

/// Personal policy survives projection/credential erasure. The service supplies
/// a verified account record; API callers cannot select another identity here.
public protocol AccountPolicyStore: Sendable {
    func policy(for account: AccountRecord) throws -> AccountPolicy
    func setPolicy(
        _ settings: NotificationSettings,
        for account: AccountRecord,
        expectedRevision: String
    ) throws -> AccountPolicy
}

struct UnavailableAccountPolicyStore: AccountPolicyStore {
    func policy(for account: AccountRecord) throws -> AccountPolicy {
        throw ServiceFailure
            .unsupportedOperation
    }

    func setPolicy(
        _ settings: NotificationSettings,
        for account: AccountRecord,
        expectedRevision: String
    ) throws -> AccountPolicy {
        throw ServiceFailure.unsupportedOperation
    }
}
