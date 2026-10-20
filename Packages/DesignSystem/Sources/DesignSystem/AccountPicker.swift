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
    let close: () -> Void
    var isOpen = false
    @FocusState private var focused: AccountPickerTarget?
    @State private var keyboardNavigation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AccountPanelHeader(title: "Accounts")
            Spacer(minLength: 0)
            if scrolls {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) { tiles }
                        .scrollIndicators(.automatic)
                        .frame(width: width)
                        .onChange(of: focused) { _, target in
                            if let target, target != .manage {
                                proxy.scrollTo(target, anchor: .center)
                            }
                        }
                }
            } else {
                tiles
            }
            Spacer(minLength: 0)
            if let manage = actions.manage {
                Button("Manage Accounts…") {
                    close()
                    manage()
                }
                .buttonStyle(.plain)
                .focusable()
                .focused($focused, equals: .manage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .frame(height: AccountPanelLayout.controlSize)
            }
        }
        .focusSection()
        .focusEffectDisabled(!keyboardNavigation)
        .onKeyPress(.tab) { keyboardNavigation = true; return .ignored }
        .onKeyPress(.return) { activateFocused() }
        .onMoveCommand { direction in
            keyboardNavigation = true
            focused = AccountPickerNavigation(state: state, actions: actions).move(
                from: focused,
                direction: direction
            )
        }
        .onChange(of: isOpen, initial: true) { _, opened in
            keyboardNavigation = false
            focused = opened ? AccountPickerNavigation(state: state, actions: actions).initial : nil
        }
    }

    private func activateFocused() -> KeyPress.Result {
        guard let focused else { return .ignored }
        switch focused {
        case let .account(id): close(); actions.select(id)
        case let .pending(id):
            guard let resume = actions.resumeSignIn else { return .ignored }
            close(); resume(id)
        case .add:
            guard let add = actions.add else { return .ignored }
            close(); add()
        case .manage:
            guard let manage = actions.manage else { return .ignored }
            close(); manage()
        }
        return .handled
    }

    private var tiles: some View {
        HStack(spacing: 0) {
            ForEach(state.accounts) { account in
                AccountTile(
                    account: account, isSelected: account.id == state.selectedID, actions: actions,
                    close: close
                )
                .focusable()
                .focused($focused, equals: .account(account.id))
                .id(AccountPickerTarget.account(account.id))
            }
            if let resume = actions.resumeSignIn {
                ForEach(state.pendingSignIns) { pending in
                    AccountActionTile(
                        title: "Finish Signing In",
                        systemImage: "person.crop.circle.badge.clock"
                    ) {
                        close()
                        resume(pending.id)
                    }
                    .focusable()
                    .focused($focused, equals: .pending(pending.id))
                    .id(AccountPickerTarget.pending(pending.id))
                }
            }
            if let add = actions.add {
                AccountActionTile(title: "Add Account", systemImage: "plus") {
                    close()
                    add()
                }
                .focusable()
                .focused($focused, equals: .add)
                .id(AccountPickerTarget.add)
            }
        }
    }
}

struct AccountTile: View {
    let account: AccountPanelAccount
    let isSelected: Bool
    let actions: AccountPanelActions
    let close: () -> Void
    @State private var hovered = false

    var body: some View {
        Button {
            close()
            actions.select(account.id)
        } label: {
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
                    .scaleEffect(hovered && !isSelected ? 1.06 : 1)
                    .padding(6)
                Text(account.label)
                    .font(.caption)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: AccountPanelLayout.tileWidth - 10)
            }
            .frame(width: AccountPanelLayout.tileWidth)
            .contentShape(.rect)
            .opacity(account.isEnabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.snappy(duration: 0.15), value: hovered)
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
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: AccountPanelLayout.tileAvatar, height: AccountPanelLayout.tileAvatar)
                    .background(Circle().fill(Color.primary.opacity(hovered ? 0.12 : 0.07)))
                    .padding(6)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: AccountPanelLayout.tileWidth)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
    }
}
