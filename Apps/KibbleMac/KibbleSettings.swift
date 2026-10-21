import AppCore
import DesignSystem
import MacHost
import SwiftUI

/// The Settings window. Under the account host it adds Settings › Accounts,
/// and the per-account panes edit the account pinned when Settings opened,
/// chosen in the pane, never whichever account the main window shows now.
/// Without the account host, Settings › Account signs the single session out.
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
        TabView(selection: selection) {
            if let host, let workspace = host.workspace {
                Tab("Accounts", systemImage: "person.2", value: SettingsPane.accounts) {
                    AccountsSettingsPane(
                        state: workspace.accountPanelState(scene: nil), actions: accountActions(host)
                    )
                    .frame(width: 560, height: 420)
                }
            }
            Tab("Notifications", systemImage: "bell.badge", value: SettingsPane.notifications) {
                scoped {
                    NotificationSettingsPane(
                        state: notificationState,
                        actions: environment.notificationSettingsActions(
                            openSystemSettings: { SystemNotificationSettings.open() }
                        )
                    )
                    .frame(width: 560, height: 540)
                }
            }
            Tab("Calls", systemImage: "phone", value: SettingsPane.calls) {
                SettingsAppWide(isShared: isShared) {
                    CallSettingsPane(
                        state: appDelegate.callSettings.state,
                        actions: appDelegate.callSettings.actions,
                        setUpCalls: appDelegate.canSetUpCalls ? { appDelegate.setUpCalls() } : nil
                    )
                    .frame(width: 560, height: 500)
                }
                .onAppear { appDelegate.callSettings.refreshFocusAccess() }
            }
            Tab("Sidebar", systemImage: "sidebar.left", value: SettingsPane.sidebar) {
                scoped {
                    SidebarSettingsPane(
                        preferences: environment.sidebarPreferences,
                        update: { [environment] in environment.updateSidebar($0) }
                    )
                    .frame(width: 560, height: 540)
                }
            }
            Tab("Downloads", systemImage: "arrow.down.circle", value: SettingsPane.downloads) {
                SettingsAppWide(isShared: isShared) {
                    DownloadSettingsPane(
                        state: appDelegate.environment.downloadSettingsState,
                        actions: appDelegate.environment.downloadSettingsActions
                    )
                    .frame(width: 560, height: 220)
                }
            }
            Tab("Updates", systemImage: "arrow.triangle.2.circlepath", value: SettingsPane.updates) {
                SettingsAppWide(isShared: isShared) {
                    UpdateSettingsPane(state: appDelegate.updates.state, actions: appDelegate.updates.actions)
                        .frame(width: 560, height: 420)
                }
            }
            // Under the account host, Accounts lists every account with its
            // own Sign Out…, and Export Diagnostics… is in the Help menu.
            if host == nil {
                Tab("Account", systemImage: "person.crop.circle", value: SettingsPane.account) {
                    AccountSettingsPane(
                        state: appDelegate.environment.accountSettingsState, signOut: legacySignOut
                    )
                    .frame(width: 560, height: 360)
                }
            }
        }
        // Pinned once, when Settings opens: the account the main window showed then.
        .onAppear { account = host?.workspace?.selectedID?.rawValue }
        .accountConfirmations(signingOut: $signingOutAccount, removing: $removingAccount, host: host)
    }

    /// The kept pane, read as one that is shown (`SettingsPane.resolve`), so a
    /// value saved before a pane was folded away still opens a pane. Reading
    /// never writes: the kept value changes only when the person picks a tab.
    private var selection: Binding<SettingsPane> {
        Binding(
            get: { SettingsPane.resolve(pane, shown: shownPanes) },
            set: { pane = $0.rawValue }
        )
    }

    /// The tabs `body` draws, in the same conditions.
    private var shownPanes: [SettingsPane] {
        var panes: [SettingsPane] = [.notifications, .calls, .sidebar, .downloads, .updates]
        if host?.workspace != nil {
            panes.append(.accounts)
        }
        if host == nil {
            panes.append(.account)
        }
        return panes
    }

    /// Several accounts are connected, so the app-wide panes say they apply to all.
    private var isShared: Bool {
        (host?.workspace?.accounts.count ?? 0) > 1
    }

    /// The pinned account's rules, and whether the Mac-wide pause beside them
    /// covers other accounts too.
    private var notificationState: NotificationSettingsState {
        var state = environment.notificationSettingsState
        state.pauseIsShared = isShared
        return state
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
