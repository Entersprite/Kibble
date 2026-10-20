import ChatAPI
import ChatKit
import DesignSystem

public extension AccountWorkspace {
    /// The account panel's values. `scene` is the selected account's, built
    /// once by the caller for its window too; every other account contributes
    /// only its own member, unread count and photo loader.
    func accountPanelState(scene: ChatSceneState?) -> AccountPanelState {
        let labels = accountLabels
        let rows = accounts.map { account in
            panelAccount(account, label: labels[account.id] ?? account.label)
        }
        let pending = pendingLinks.filter { link in
            link.id != capture?.id && !accounts.contains { $0.id == link.accountID }
        }
        return AccountPanelState(
            accounts: rows,
            pendingSignIns: pending.map { AccountPanelPendingSignIn(id: $0.id.rawValue) },
            selectedID: selectedID?.rawValue,
            scene: selectedEnvironment == nil ? nil : scene
        )
    }

    /// What the selected account's window says while it is not running, or
    /// `nil` while it runs.
    func unavailableReason(for id: ConnectedAccountID) -> AccountUnavailable.Reason? {
        guard environment(for: id) == nil, let account = accounts.first(where: { $0.id == id }) else {
            return nil
        }
        if account.isRemoving || account.authenticationState == "erasing" {
            return .removing
        }
        if let error = accountErrors[account.id] {
            return .failed(error)
        }
        if !account.isEnabled {
            return .disabled
        }
        return account.authenticationState == nil ? .connecting : .signInRequired
    }

    private func panelAccount(_ account: AccountSummary, label: String) -> AccountPanelAccount {
        let environment = environment(for: account.id)
        let own = environment?.ownIdentity
        let me = own?.me ?? account.selfID
        // A disabled or signed-out account still has a face: initials from the
        // name the service last learned.
        let member = own?.member ?? Member(
            id: me, kind: .human, displayName: account.profile?.displayName, email: account.profile?.email
        )
        var managedBy: String?
        if case let .managed(domain) = account.profile?.organization {
            managedBy = domain
        }
        var problem: AccountPanelAccount.Problem?
        if account.authenticationState == "required" {
            problem = .signInRequired
        } else if accountErrors[account.id] != nil {
            problem = .failed
        }
        return AccountPanelAccount(
            id: account.id.rawValue, label: label,
            name: member.displayName ?? account.profile?.displayName,
            email: member.email ?? account.profile?.email,
            managedBy: managedBy, unread: environment?.badgeCount ?? 0, problem: problem,
            isEnabled: account.isEnabled, me: me, directory: [me: member],
            imageLoader: environment?.imageLoader
        )
    }
}

public extension AppEnvironment {
    /// The signed-in member, without building a whole scene.
    var ownIdentity: (me: Member.ID, member: Member?)? {
        guard case let .running(model) = phase, let me = model.me else { return nil }
        return (me, model.directory[me])
    }
}
