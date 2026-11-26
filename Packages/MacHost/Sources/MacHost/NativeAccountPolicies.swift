import AppCore
import ChatAPI
import ChatKit
import ChatService
import Foundation

/// Completes identity settings cleanup inside the service's durable removal
/// intent, including when removal resumes after the app was interrupted.
struct NativeAccountPolicies: AccountPolicyStore, AccountPolicyForgetting, DefaultPolicyStore {
    let base: any AccountPolicyStore
    let namespace: String
    let preferenceSuite: String?

    func policy(for account: AccountRecord) throws -> AccountPolicy {
        try base.policy(for: account)
    }

    func setPolicy(
        _ settings: NotificationSettings, for account: AccountRecord, expectedRevision: String
    ) throws -> AccountPolicy {
        try base.setPolicy(settings, for: account, expectedRevision: expectedRevision)
    }

    func defaultPolicy(for principal: ServicePrincipalID) throws -> AccountPolicy {
        guard let store = base as? any DefaultPolicyStore else { throw ServiceFailure.unsupportedOperation }
        return try store.defaultPolicy(for: principal)
    }

    func setDefaultPolicy(
        _ rule: NotificationRule, for principal: ServicePrincipalID, expectedRevision: String
    ) throws -> AccountPolicy {
        guard let store = base as? any DefaultPolicyStore else { throw ServiceFailure.unsupportedOperation }
        return try store.setDefaultPolicy(rule, for: principal, expectedRevision: expectedRevision)
    }

    func forgetPolicy(for account: AccountRecord) throws {
        guard let forgetting = base as? any AccountPolicyForgetting else {
            throw ServiceFailure.unsupportedOperation
        }
        try forgetting.forgetPolicy(for: account)
        let preferences = preferenceSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        AppEnvironment.forgetPersonalPreferences(
            namespace: namespace, identity: account.selfID, in: preferences
        )
    }
}
