import ChatKit
import SwiftUI

/// Every account as a large round avatar labeled by what sets it apart, then
/// unfinished sign-ins and Add Account. Choosing one closes the panel.
struct AccountPickerSection: View {
    let state: AccountPanelState
    let actions: AccountPanelActions
    let width: CGFloat
    /// Grown to the window's edge and still too narrow for every tile.
    let scrolls: Bool
    let commands: AccountPanelCommands
    @Binding var highlight: AccountPanelTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AccountPanelHeader(title: "Accounts")
            Spacer(minLength: 0)
            if scrolls {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) { tiles }
                        .scrollIndicators(.automatic)
                        .frame(width: width)
                        .onChange(of: highlight) { _, target in
                            if let target, target != .manage {
                                proxy.scrollTo(target, anchor: .center)
                            }
                        }
                }
            } else {
                tiles
            }
            Spacer(minLength: 0)
            if actions.manage != nil {
                Button("Manage Accounts…") { commands.perform(.manage) }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(AccountPanelHighlight(isOn: highlight == .manage))
                    .contentShape(.rect)
                    .accountPanelHover(.manage, highlight: $highlight)
                    .frame(height: AccountPanelLayout.controlSize)
            }
        }
    }

    private var tiles: some View {
        HStack(spacing: 0) {
            ForEach(state.accounts) { account in
                let target = AccountPanelTarget.account(account.id)
                AccountTile(
                    account: account, isSelected: account.id == state.selectedID,
                    isHighlighted: highlight == target, actions: actions
                ) { commands.perform(target) }
                    .accountPanelHover(target, highlight: $highlight)
                    .id(target)
            }
            if actions.resumeSignIn != nil {
                ForEach(state.pendingSignIns) { pending in
                    let target = AccountPanelTarget.pending(pending.id)
                    AccountActionTile(
                        title: "Finish Signing In", systemImage: "person.crop.circle.badge.clock",
                        isHighlighted: highlight == target
                    ) { commands.perform(target) }
                        .accountPanelHover(target, highlight: $highlight)
                        .id(target)
                }
            }
            if actions.add != nil {
                let target = AccountPanelTarget.add
                AccountActionTile(
                    title: "Add Account", systemImage: "plus", isHighlighted: highlight == target
                ) { commands.perform(target) }
                    .accountPanelHover(target, highlight: $highlight)
                    .id(target)
            }
        }
    }
}

struct AccountTile: View {
    let account: AccountPanelAccount
    let isSelected: Bool
    /// Under the pointer, or where the arrow keys put the highlight.
    let isHighlighted: Bool
    let actions: AccountPanelActions
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            VStack(spacing: 7) {
                Avatar(member: account.me, directory: account.directory, size: AccountPanelLayout.tileAvatar)
                    .environment(\.sceneImageLoader, account.imageLoader)
                    .overlay {
                        if isSelected {
                            Circle()
                                .strokeBorder(Color.accentColor, lineWidth: 2.5)
                                .padding(-5)
                        }
                    }
                    .overlay(alignment: .topTrailing) { badge.offset(x: 7, y: -5) }
                    .scaleEffect(isHighlighted && !isSelected ? 1.06 : 1)
                    .padding(6)
                Text(account.label)
                    .font(.caption)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: AccountPanelLayout.tileWidth - 10)
            }
            .padding(.vertical, 4)
            .frame(width: AccountPanelLayout.tileWidth)
            .opacity(account.isEnabled ? 1 : 0.45)
            .background(AccountPanelHighlight(isOn: isHighlighted, cornerRadius: 14).padding(.horizontal, 2))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.15), value: isHighlighted)
        .help(help)
        .contextMenu { menu }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(account.label)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private var badge: some View {
        if account.problem != nil {
            AccountIssueBadge(size: 20)
        } else if account.unread > 0, !isSelected {
            AccountCountBadge(count: account.unread)
        }
    }

    private var help: String {
        [account.name, account.email, account.managedBy.map { "Managed by \($0)" }]
            .compactMap(\.self).joined(separator: "\n")
    }

    private var accessibilityValue: String {
        var parts = [account.name].compactMap(\.self)
        if isSelected {
            parts.append("current account")
        }
        switch account.problem {
        case .signInRequired: parts.append("needs to sign in again")
        case .failed: parts.append("could not connect")
        case nil:
            if account.unread > 0, !isSelected {
                parts.append("\(account.unread) unread")
            }
        }
        if !account.isEnabled {
            parts.append("disabled")
        }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder private var menu: some View {
        if let reconnect = actions.reconnect, let problem = account.problem {
            Button(problem == .signInRequired ? "Reconnect…" : "Retry") { reconnect(account.id) }
        }
        if let setEnabled = actions.setEnabled {
            Button(account.isEnabled ? "Disable" : "Enable") { setEnabled(account.id, !account.isEnabled) }
        }
        if actions.signOut != nil || actions.remove != nil {
            Divider()
        }
        // Not once signed out: Reconnect is what it needs then.
        if let signOut = actions.signOut, account.problem != .signInRequired {
            Button("Sign Out…") { signOut(account.id) }
        }
        if let remove = actions.remove {
            Button("Remove Account…", role: .destructive) { remove(account.id) }
        }
    }
}

/// A round tile for something to do rather than an account: Add Account, or
/// finishing a sign-in.
struct AccountActionTile: View {
    let title: String
    let systemImage: String
    let isHighlighted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: AccountPanelLayout.tileAvatar, height: AccountPanelLayout.tileAvatar)
                    .background(Circle().fill(Color.primary.opacity(isHighlighted ? 0.12 : 0.07)))
                    .padding(6)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.vertical, 4)
            .frame(width: AccountPanelLayout.tileWidth)
            .background(AccountPanelHighlight(isOn: isHighlighted, cornerRadius: 14).padding(.horizontal, 2))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
    }
}
