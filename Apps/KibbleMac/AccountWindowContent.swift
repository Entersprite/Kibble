import AppCore
import DesignSystem
import MacHost
import SwiftUI

/// The main window under the account host: the selected account's window,
/// or why it has none, with the account pill always reachable once there is
/// an account. Assembly only; the workspace decides every value.
struct AccountWindowContent: View {
    let host: SystemAccountHost
    /// The shell's own actions for a running account's window.
    let chatActions: (AppEnvironment, @escaping () -> Void) -> ChatSceneActions
    @Binding var isPanelOpen: Bool
    /// Ask to sign out or remove an account; the shell confirms first.
    let signOutAccount: (String) -> Void
    let removeAccount: (String) -> Void
    let manageAccounts: (@escaping () -> Void) -> Void

    var body: some View {
        SettingsOpening { showSettings in
            if let workspace = host.workspace, !workspace.isLoading {
                if workspace.accounts.isEmpty {
                    AccountsPlaceholder(phase: .noAccounts) { Task { await host.addAccount() } }
                } else {
                    shell(workspace, showSettings: showSettings)
                }
            } else if host.workspace == nil, let error = host.error {
                AccountsPlaceholder(phase: .failed(error), retry: { Task { await host.start() } })
            } else {
                AccountsPlaceholder(phase: .starting)
            }
        }
        .overlay(alignment: .top) {
            if host.workspace != nil, let error = host.error {
                HStack(spacing: 12) {
                    Text(error)
                    Button("Dismiss") { host.dismissError() }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
                .padding(.top, 60)
            }
        }
        .alert(
            "That Is a Different Google Account",
            isPresented: Binding(
                get: { host.refusedSignIn != nil },
                set: {
                    if !$0 {
                        host.dismissRefusedSignIn()
                    }
                }
            ),
            presenting: host.refusedSignIn
        ) { id in
            Button("Try Again") {
                host.dismissRefusedSignIn()
                Task { await host.retryAccount(id) }
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { host.dismissRefusedSignIn() }
        } message: { id in
            Text(refusalMessage(id))
        }
    }

    /// Which account to sign in with: the account only reconnects as itself.
    private func refusalMessage(_ id: String) -> String {
        let account = host.workspace?.accounts.first { $0.id.rawValue == id }
        let label = host.workspace?.accountLabels.first { $0.key.rawValue == id }?.value ?? "this account"
        guard let email = account?.profile?.email, email != label else {
            return "\(label) can only sign in again as the same Google account."
        }
        return "To reconnect \(label), sign in as \(email)."
    }

    private func shell(_ workspace: AccountWorkspace, showSettings: @escaping () -> Void) -> some View {
        let environment = workspace.selectedEnvironment
        let scene = workspace.selectedScene() ?? ChatSceneState()
        return AccountShell(
            state: workspace.accountPanelState(scene: environment == nil ? nil : scene),
            actions: panelActions(environment, showSettings: showSettings),
            isPanelOpen: $isPanelOpen
        ) {
            if let environment {
                ChatWindow(state: scene, actions: chatActions(environment, showSettings))
            } else {
                ChatWindow(
                    state: scene, actions: ChatSceneActions(showSettings: showSettings),
                    unavailable: unavailable(workspace)
                )
            }
        }
    }

    private func panelActions(_ environment: AppEnvironment?, showSettings: @escaping () -> Void)
        -> AccountPanelActions {
        let actions = environment?.actions
        return AccountPanelActions(
            select: { host.selectAccount($0) },
            add: { Task { await host.addAccount() } },
            resumeSignIn: { id in Task { await host.resumeSignIn(id) } },
            manage: { manageAccounts(showSettings) },
            reconnect: { id in Task { await host.retryAccount(id) } },
            setEnabled: { id, enabled in Task { await host.setEnabled(enabled, account: id) } },
            signOut: signOutAccount,
            remove: removeAccount,
            showSettings: showSettings,
            setAvailability: actions?.setAvailability,
            setStatus: actions?.setStatus,
            reactions: actions?.reactions
        )
    }

    private func unavailable(_ workspace: AccountWorkspace) -> AccountUnavailable? {
        guard let id = workspace.selectedID, let reason = workspace.unavailableReason(for: id) else {
            return nil
        }
        let label = workspace.accountLabels[id] ?? "This account"
        return AccountUnavailable(
            label: label, reason: reason,
            enable: { Task { await host.setEnabled(true, account: id.rawValue) } },
            reconnect: { Task { await host.retryAccount(id.rawValue) } }
        )
    }
}

extension View {
    /// Confirms signing out of, or removing, the account in `id`, captured when
    /// asked. Sign Out keeps the account and its settings; Remove forgets both.
    func accountConfirmations(
        signingOut: Binding<String?>, removing: Binding<String?>, host: SystemAccountHost?
    ) -> some View {
        sheet(isPresented: AccountConfirmation.isPresented(signingOut)) {
            if let id = signingOut.wrappedValue {
                AccountConfirmationSheet(
                    label: AccountConfirmation.label(id, host: host), removing: false,
                    confirm: {
                        signingOut.wrappedValue = nil
                        if let host {
                            Task { await host.signOutAccount(id) }
                        }
                    }, cancel: { signingOut.wrappedValue = nil }
                )
            }
        }
        .sheet(isPresented: AccountConfirmation.isPresented(removing)) {
            if let id = removing.wrappedValue {
                AccountConfirmationSheet(
                    label: AccountConfirmation.label(id, host: host), removing: true,
                    confirm: {
                        removing.wrappedValue = nil
                        if let host {
                            Task { await host.removeAccount(id) }
                        }
                    }, cancel: { removing.wrappedValue = nil }
                )
            }
        }
    }
}

private enum AccountConfirmation {
    @MainActor
    static func label(_ id: String, host: SystemAccountHost?) -> String {
        host?.workspace?.accountLabels.first { $0.key.rawValue == id }?.value ?? "this account"
    }

    static func isPresented(_ id: Binding<String?>) -> Binding<Bool> {
        Binding(get: { id.wrappedValue != nil }, set: {
            if !$0 {
                id.wrappedValue = nil
            }
        })
    }
}

/// The Accounts menu under the account host: each account, ⌃⌘1…9 in list
/// order, the account panel on ⌃⌘0, and adding or managing accounts.
struct AccountCommands: Commands {
    let host: SystemAccountHost?
    @Binding var isPanelOpen: Bool
    /// Chooses the Settings pane that manages accounts.
    let selectAccountsPane: () -> Void
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some Commands {
        if let host {
            CommandMenu("Accounts") {
                let workspace = host.workspace
                let labels = workspace?.accountLabels ?? [:]
                let accounts = Array((workspace?.accounts ?? []).prefix(9).enumerated())
                ForEach(accounts, id: \.element.id) { index, account in
                    Toggle(labels[account.id] ?? account.label, isOn: Binding(
                        get: { workspace?.selectedID == account.id },
                        set: { _ in
                            openWindow(id: MainWindow.id)
                            host.selectAccount(account.id.rawValue)
                        }
                    ))
                    .keyboardShortcut(
                        KeyEquivalent(Character(String(index + 1))),
                        modifiers: [.control, .command]
                    )
                }
                Divider()
                Button(isPanelOpen ? "Hide Account Panel" : "Show Account Panel") {
                    openWindow(id: MainWindow.id)
                    isPanelOpen.toggle()
                }
                .keyboardShortcut("0", modifiers: [.control, .command])
                .disabled(workspace?.accounts.isEmpty ?? true)
                Divider()
                Button("Add Account…") { Task { await host.addAccount() } }
                Button("Manage Accounts…") {
                    selectAccountsPane()
                    openSettings()
                }
            }
        }
    }
}
