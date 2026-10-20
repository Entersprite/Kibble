import ChatKit
import SwiftUI

/// Settings › Accounts: every connected account in list order, with what can
/// be done to it, and Add Account. Drag a row to change the order the account
/// panel and ⌃⌘1…9 follow.
public struct AccountsSettingsPane: View {
    private let state: AccountPanelState
    private let actions: AccountPanelActions

    public init(state: AccountPanelState, actions: AccountPanelActions) {
        self.state = state
        self.actions = actions
    }

    public var body: some View {
        Form {
            Section {
                ForEach(state.accounts) { account in
                    AccountsSettingsRow(account: account, actions: actions)
                }
                .onMove(perform: actions.reorder.map { reorder in
                    { source, destination in
                        var ids = state.accounts.map(\.id)
                        ids.move(fromOffsets: source, toOffset: destination)
                        reorder(ids)
                    }
                })
            } footer: {
                Text(footer)
            }
            if let add = actions.add {
                Section {
                    Button("Add Account…", action: add)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var footer: String {
        let order = actions.reorder == nil ? "" : "Drag an account to change the order. "
        return order + "Control-Command-1 through 9 switch to the first nine accounts. "
            + "Signing out keeps an account and its settings until you sign in again with it; "
            + "removing it also forgets its settings."
    }
}

struct AccountsSettingsRow: View {
    let account: AccountPanelAccount
    let actions: AccountPanelActions

    var body: some View {
        HStack(spacing: 12) {
            Avatar(member: account.me, directory: account.directory, size: 32)
                .environment(\.sceneImageLoader, account.imageLoader)
                .opacity(account.isEnabled ? 1 : 0.45)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(statusText)
                .font(.callout)
                .foregroundStyle(account.status == .connected ? .secondary : .primary)
            Menu {
                menu
            } label: {
                Label("Actions for \(account.label)", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .contextMenu { menu }
    }

    /// The email, and who manages the account when its label does not already say.
    private var detail: String {
        let managed = account.managedBy.flatMap { $0 == account.label ? nil : "Managed by \($0)" }
        return [account.email, managed].compactMap(\.self).joined(separator: " · ")
    }

    private var statusText: String {
        switch account.status {
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .disabled: "Disabled"
        case .signedOut: "Signed out"
        case .failed: "Could not connect"
        case .removing: "Removing…"
        }
    }

    @ViewBuilder private var menu: some View {
        if let reconnect = actions.reconnect, account.status == .signedOut || account.status == .failed {
            Button(account.status == .signedOut ? "Sign In…" : "Try Again") { reconnect(account.id) }
        }
        if let setEnabled = actions.setEnabled, account.status != .removing {
            Button(account.isEnabled ? "Disable" : "Enable") { setEnabled(account.id, !account.isEnabled) }
        }
        if account.status != .removing {
            Divider()
            if let signOut = actions.signOut, account.status != .signedOut {
                Button("Sign Out…") { signOut(account.id) }
            }
            if let remove = actions.remove {
                Button("Remove Account…", role: .destructive) { remove(account.id) }
            }
        }
    }
}
