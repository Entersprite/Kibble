import AppCore
import DesignSystem
import MacHost
import SwiftUI

/// The Settings window. Under the account host it adds Settings › Accounts,
/// and the per-account panes edit the account pinned when Settings opened,
/// chosen in the pane, never whichever account the main window shows now.
struct KibbleSettings: View {
    let appDelegate: MacAppDelegate
    @Binding var pane: String
    /// Without the account host: the single session's own sign-out, confirmed by the shell.
    let legacySignOut: (() -> Void)?
    @State private var account: String?
    @State private var signingOutAccount: String?
    @State private var removingAccount: String?

    private var host: SystemAccountHost? {
        appDelegate.accountHost
    }

    var body: some View {
        TabView(selection: $pane) {
            if let host, let workspace = host.workspace {
                Tab("Accounts", systemImage: "person.2", value: "accounts") {
                    AccountsSettingsPane(
                        state: workspace.accountPanelState(scene: nil), actions: accountActions(host)
                    )
                    .frame(width: 560, height: 420)
                }
            }
            Tab("Notifications", systemImage: "bell.badge", value: "notifications") {
                scoped {
                    NotificationSettingsPane(
                        state: environment.notificationSettingsState,
                        actions: environment.notificationSettingsActions(
                            openSystemSettings: { SystemNotificationSettings.open() }
                        )
                    )
                    .frame(width: 560, height: 540)
                }
            }
            Tab("Calls", systemImage: "phone", value: "calls") {
                CallSettingsPane(
                    state: appDelegate.callSettings.state,
                    actions: appDelegate.callSettings.actions,
                    setUpCalls: appDelegate.canSetUpCalls ? { appDelegate.setUpCalls() } : nil
                )
                .frame(width: 560, height: 500)
                .onAppear { appDelegate.callSettings.refreshFocusAccess() }
            }
            Tab("Conversations", systemImage: "bubble.left.and.bubble.right", value: "conversations") {
                scoped {
                    ConversationSettingsPane(
                        state: environment.notificationSettingsState,
                        actions: environment.notificationSettingsActions(
                            openSystemSettings: { SystemNotificationSettings.open() }
                        )
                    )
                    .frame(width: 560, height: 420)
                }
            }
            Tab("Sidebar", systemImage: "sidebar.left", value: "sidebar") {
                scoped {
                    SidebarSettingsPane(
                        preferences: environment.sidebarPreferences,
                        update: { [environment] in environment.updateSidebar($0) }
                    )
                    .frame(width: 560, height: 540)
                }
            }
            Tab("Downloads", systemImage: "arrow.down.circle", value: "downloads") {
                DownloadSettingsPane(
                    state: appDelegate.environment.downloadSettingsState,
                    actions: appDelegate.environment.downloadSettingsActions
                )
                .frame(width: 560, height: 220)
            }
            Tab("Updates", systemImage: "arrow.triangle.2.circlepath", value: "updates") {
                UpdateSettingsPane(state: appDelegate.updates.state, actions: appDelegate.updates.actions)
                    .frame(width: 560, height: 420)
            }
            Tab("Account", systemImage: "person.crop.circle", value: "account") {
                scoped {
                    AccountSettingsPane(
                        state: environment.accountSettingsState,
                        signOut: signOut,
                        exportDiagnostics: { appDelegate.diagnostics.export() }
                    )
                    .frame(width: 560, height: 360)
                }
            }
        }
        // Pinned once, when Settings opens: the account the main window showed then.
        .onAppear { account = host?.workspace?.selectedID?.rawValue }
        .accountConfirmations(signingOut: $signingOutAccount, removing: $removingAccount, host: host)
    }

    /// The pinned account's environment; without the account host, the session's own.
    private var environment: AppEnvironment {
        guard let workspace = host?.workspace,
              let summary = workspace.accounts.first(where: { $0.id.rawValue == account }),
              let pinned = workspace.environment(for: summary.id) else { return appDelegate.environment }
        return pinned
    }

    private func scoped(@ViewBuilder _ content: () -> some View) -> some View {
        let workspace = host?.workspace
        let labels = workspace?.accountLabels ?? [:]
        let choices = (workspace?.accounts ?? []).map { summary in
            SettingsAccountChoice(id: summary.id.rawValue, label: labels[summary.id] ?? summary.label)
        }
        let available = workspace == nil || workspace?.accounts.first(where: { $0.id.rawValue == account })
            .map { workspace?.environment(for: $0.id) != nil } == true
        return SettingsAccountScope(choices: choices, selection: $account, isAvailable: available) {
            content()
        }
    }

    /// Signs out the pinned account under the account host.
    private var signOut: (() -> Void)? {
        guard let host else { return legacySignOut }
        guard let workspace = host.workspace,
              let summary = workspace.accounts.first(where: { $0.id.rawValue == account }),
              summary.authenticationState == nil else { return nil }
        let id = summary.id.rawValue
        return { signingOutAccount = id }
    }

    private func accountActions(_ host: SystemAccountHost) -> AccountPanelActions {
        AccountPanelActions(
            select: { host.selectAccount($0) },
            add: { Task { await host.addAccount() } },
            reconnect: { id in Task { await host.retryAccount(id) } },
            setEnabled: { id, enabled in Task { await host.setEnabled(enabled, account: id) } },
            signOut: { signingOutAccount = $0 },
            remove: { removingAccount = $0 },
            reorder: { ids in Task { await host.reorderAccounts(ids) } }
        )
    }
}
