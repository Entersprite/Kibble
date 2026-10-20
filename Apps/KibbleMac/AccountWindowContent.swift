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
    /// Asks to remove an account; the shell confirms first.
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
    }

    private func shell(_ workspace: AccountWorkspace, showSettings: @escaping () -> Void) -> some View {
        let environment = workspace.selectedEnvironment
        let scene = environment?.sceneState ?? ChatSceneState()
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
            manage: { manageAccounts(showSettings) },
            reconnect: { id in Task { await host.retryAccount(id) } },
            setEnabled: { id, enabled in Task { await host.setEnabled(enabled, account: id) } },
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
