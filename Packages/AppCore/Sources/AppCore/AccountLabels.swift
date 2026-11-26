import ChatAPI
import ChatKit

/// How each account is named where accounts sit side by side: the domain that
/// manages it, "Personal" for an account no organization manages, otherwise its
/// email. Two accounts that would read the same show their emails instead.
///
/// Display only, from the service's profile: never derived from an email's
/// domain, which says nothing about who manages an account.
public enum AccountLabels {
    public static let personal = "Personal"

    public static func labels(for accounts: [AccountSummary]) -> [ConnectedAccountID: String] {
        var uses: [String: Int] = [:]
        for account in accounts {
            uses[base(account).lowercased(), default: 0] += 1
        }
        var labels: [ConnectedAccountID: String] = [:]
        for account in accounts {
            let base = base(account)
            labels[account.id] = uses[base.lowercased(), default: 0] > 1 ? identity(account) : base
        }
        return labels
    }

    static func base(_ account: AccountSummary) -> String {
        switch account.profile?.organization {
        case let .managed(domain): domain
        case .personal: personal
        case .unstated, .unknown, nil: identity(account)
        }
    }

    /// The most specific identity known: the email, then the name, then the
    /// service's own label for the account.
    static func identity(_ account: AccountSummary) -> String {
        account.profile?.email ?? account.profile?.displayName ?? account.label
    }
}

public extension AccountWorkspace {
    var accountLabels: [ConnectedAccountID: String] {
        AccountLabels.labels(for: accounts)
    }
}
