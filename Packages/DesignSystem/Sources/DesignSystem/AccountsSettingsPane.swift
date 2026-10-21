import ChatKit
import SwiftUI

/// Settings › Accounts: every connected account in list order, with what can
/// be done to it, and Add Account. The order, which the account panel and
/// ⌃⌘1…9 follow, changes by dragging a row or from its menu (`SettingsOrder`).
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
                    AccountsSettingsRow(
                        account: account, actions: actions,
                        place: actions.reorder == nil
                            ? SettingsRowPlace(canMoveUp: false, canMoveDown: false)
                            : SettingsOrder.place(of: account.id, in: state.accounts),
                        move: { move(account.id, $0) }
                    )
                }
                .onMove(perform: drag)
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

    /// No drag where the host cannot reorder.
    private var drag: ((IndexSet, Int) -> Void)? {
        guard let reorder = actions.reorder else { return nil }
        let accounts = state.accounts
        return { source, destination in
            reorder(SettingsOrder.moving(accounts, fromOffsets: source, toOffset: destination).map(\.id))
        }
    }

    private func move(_ id: String, _ direction: SettingsMove) {
        guard let reorder = actions.reorder,
              let moved = SettingsOrder.moving(id, direction, in: state.accounts) else { return }
        reorder(moved.map(\.id))
    }

    private var footer: String {
        let order = actions.reorder == nil ? "" : "To change the order, drag an account or use its menu. "
        return order + "Control-Command-1 through 9 switch to the first nine accounts. "
            + "Signing out keeps an account and its settings until you sign in again with it; "
            + "removing it also forgets its settings."
    }
}

struct AccountsSettingsRow: View {
    let account: AccountPanelAccount
    let actions: AccountPanelActions
    let place: SettingsRowPlace
    let move: (SettingsMove) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Avatar(member: account.me, directory: account.directory, size: 32).besideName()
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
            AccountsSettingsStatus(status: account.status)
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
        .settingsMoveActions(place, move: move)
        .contextMenu { menu }
    }

    /// The email, and who manages the account when its label does not already say.
    private var detail: String {
        let managed = account.managedBy.flatMap { $0 == account.label ? nil : "Managed by \($0)" }
        return [account.email, managed].compactMap(\.self).joined(separator: " · ")
    }

    @ViewBuilder private var menu: some View {
        if let reconnect = actions.reconnect, account.status == .signedOut || account.status == .failed {
            if account.status == .signedOut {
                Button("Sign In…", systemImage: "person.crop.circle") { reconnect(account.id) }
            } else {
                Button("Try Again", systemImage: "arrow.clockwise") { reconnect(account.id) }
            }
        }
        if let setEnabled = actions.setEnabled, account.status != .removing {
            if account.isEnabled {
                Button("Disable", systemImage: "pause.circle") { setEnabled(account.id, false) }
            } else {
                Button("Enable", systemImage: "play.circle") { setEnabled(account.id, true) }
            }
        }
        if place.isReorderable {
            Divider()
            SettingsMoveMenuItems(place: place, move: move)
        }
        if account.status != .removing {
            Divider()
            if let signOut = actions.signOut, account.status != .signedOut {
                Button("Sign Out…", systemImage: "rectangle.portrait.and.arrow.right") { signOut(account.id) }
            }
            if let remove = actions.remove {
                Button("Remove Account…", systemImage: "trash", role: .destructive) { remove(account.id) }
            }
        }
    }
}

/// An account row's state: quiet while connected or connecting, a warning
/// only when it could not connect. Connecting is progress, not a problem.
struct AccountsSettingsStatus: View {
    let status: AccountPanelAccount.Status

    var body: some View {
        switch status {
        case .connecting:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(Self.title(of: status))
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        case .failed:
            Label(Self.title(of: status), systemImage: "exclamationmark.triangle.fill")
                .labelStyle(AccountsSettingsWarningStyle())
                .font(.callout)
        default:
            Text(Self.title(of: status))
                .font(.callout)
                .foregroundStyle(status == .connected ? .secondary : .primary)
        }
    }

    nonisolated static func title(of status: AccountPanelAccount.Status) -> String {
        switch status {
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .disabled: "Disabled"
        case .signedOut: "Signed out"
        case .failed: "Could not connect"
        case .removing: "Removing…"
        }
    }
}

/// The system's caution glyph beside primary text, as System Settings marks an
/// item that needs attention. Multicolor, so the symbol carries the system's
/// own warning colors rather than a fixed yellow.
private struct AccountsSettingsWarningStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
                .symbolRenderingMode(.multicolor)
                .imageScale(.medium)
            configuration.title
        }
    }
}
