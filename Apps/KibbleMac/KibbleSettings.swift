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
    @State private var deletingData = false
    @State private var deletionError: String?

    private var host: SystemAccountHost? {
        appDelegate.accountHost
    }

    var body: some View {
        TabView(selection: selection) {
            if let host {
                Tab("Accounts", systemImage: "person.2", value: SettingsPane.accounts) {
                    AccountsSettingsPane(
                        state: host.workspace?.accountPanelState(scene: nil) ?? AccountPanelState(
                            accounts: [],
                            selectedID: nil,
                            scene: nil
                        ),
                        actions: accountActions(host),
                        reset: deleteAllData,
                        resetMessage: Self.deletionMessage
                    )
                    .frame(width: 560, height: 420)
                }
            }
            Tab("Notifications", systemImage: "bell.badge", value: SettingsPane.notifications) {
                scoped(showsHeader: false) {
                    NotificationSettingsPane(
                        state: notificationState,
                        actions: notificationActions
                    )
                    .frame(width: 560, height: 540)
                }
            }
            Tab("Calls", systemImage: "phone", value: SettingsPane.calls) {
                CallSettingsPane(
                    state: appDelegate.callSettings.state,
                    actions: appDelegate.callSettings.actions,
                    setUpCalls: appDelegate.canSetUpCalls ? { appDelegate.setUpCalls() } : nil,
                    reset: { appDelegate.callSettings.reset() }
                )
                .frame(width: 560, height: 500)
                .onAppear { appDelegate.callSettings.refreshFocusAccess() }
            }
            Tab("Sidebar", systemImage: "sidebar.left", value: SettingsPane.sidebar) {
                scoped {
                    sidebarPane
                        .frame(width: 560, height: 540)
                }
            }
            Tab("Downloads", systemImage: "arrow.down.circle", value: SettingsPane.downloads) {
                DownloadSettingsPane(
                    state: appDelegate.environment.downloadSettingsState,
                    actions: appDelegate.environment.downloadSettingsActions,
                    reset: appDelegate.environment.downloadSettingsActions.useDefault
                )
                .frame(width: 560, height: 220)
            }
            Tab("Updates", systemImage: "arrow.triangle.2.circlepath", value: SettingsPane.updates) {
                UpdateSettingsPane(
                    state: appDelegate.updates.state, actions: appDelegate.updates.actions,
                    reset: { appDelegate.updates.reset() }
                )
                .frame(width: 560, height: 420)
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
        .onAppear {
            account = host?.workspace?.selectedID?.rawValue
            Task { await host?.defaultPolicy?.load() }
        }
        .environment(\.notificationSoundActions, NotificationSoundLibrary.actions)
        .disabled(deletingData)
        .overlay {
            if deletingData {
                ProgressView("Deleting User Data…").padding()
            }
        }
        .alert("Couldn’t Delete All User Data", isPresented: Binding(
            get: { deletionError != nil }, set: {
                if !$0 {
                    deletionError = nil
                }
            }
        )) {
            Button("OK") { deletionError = nil }
        } message: { Text(deletionError ?? "") }
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
        if host != nil {
            panes.append(.accounts)
        }
        if host == nil {
            panes.append(.account)
        }
        return panes
    }

    /// Whether the shared notification pause covers multiple connected accounts.
    private var isShared: Bool {
        (host?.workspace?.accounts.count ?? 0) > 1
    }

    /// The pinned account's rules, and whether the Mac-wide pause beside them
    /// covers other accounts too.
    private var notificationState: NotificationSettingsState {
        var state: NotificationSettingsState
        if account == nil, let host {
            state = host.defaultPolicy?.settingsState(devicePause: host.deviceNotificationPause)
                ?? NotificationSettingsState()
            state.editsSharedDefaults = true
        } else {
            state = environment.notificationSettingsState
        }
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

    private func scoped(showsHeader: Bool = true, @ViewBuilder _ content: () -> some View) -> some View {
        let workspace = host?.workspace
        let labels = workspace?.accountLabels ?? [:]
        let choices = (workspace?.accounts ?? []).map { summary in
            SettingsAccountChoice(id: summary.id.rawValue, label: labels[summary.id] ?? summary.label)
        }
        let available = workspace == nil || account == nil || workspace?.accounts
            .first(where: { $0.id.rawValue == account })
            .map { workspace?.environment(for: $0.id) != nil } == true
        return SettingsAccountScope(
            choices: choices, selection: $account, isAvailable: available, showsHeader: showsHeader
        ) {
            content()
        }
    }

    private var notificationActions: NotificationSettingsActions {
        var actions = if account == nil, let model = host?.defaultPolicy {
            model.settingsActions(
                openSystemSettings: { SystemNotificationSettings.open() },
                devicePause: host?.deviceNotificationPause
            )
        } else {
            environment
                .notificationSettingsActions(openSystemSettings: { SystemNotificationSettings.open() })
        }
        actions.sendTest = appDelegate.sendTestNotification
        return actions
    }

    @ViewBuilder private var sidebarPane: some View {
        if account == nil, let host {
            SidebarSettingsPane(
                preferences: host.globalSidebar, update: { host.updateGlobalSidebar($0) },
                reset: { host.updateGlobalSidebar(nil) },
                resetMessage: "Reset global sidebar defaults? Account overrides are kept. "
                    + "This cannot be undone."
            )
        } else {
            SidebarSettingsPane(
                preferences: environment.sidebarPreferences,
                update: { [environment] in environment.updateSidebar($0) },
                reset: { [environment] in environment.resetSidebar() },
                resetMessage: "Reset sidebar settings for this account? This cannot be undone."
            )
        }
    }

    private static let deletionMessage = "Delete all accounts, logins, settings, messages, drafts, "
        + "and other data stored by Kibble? Files saved outside Kibble are kept. This cannot be undone."

    private func deleteAllData() {
        guard !deletingData else { return }
        deletingData = true
        Task {
            do {
                try await appDelegate.deleteAllUserData()
                account = nil
            } catch {
                deletionError = "Some Kibble data could not be removed. Try again to finish deleting it."
            }
            deletingData = false
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
