import AppCore
import DesignSystem
import MacHost
import SwiftUI

/// The shell.
///
/// Everything this file does is assemble packages and hand the window a model.
/// There is deliberately no logic here: CLAUDE.md's structure rule is that the
/// app target is a shell so that `sourcekit-lsp` and `swift test` keep working
/// without Xcode, and so that a second app - iOS, later - assembles the same
/// pieces rather than reimplementing them.
///
/// The session belongs to `MacAppDelegate`, not to this struct or its window:
/// it starts at launch and keeps running with the window closed, which is what
/// lets notifications arrive. See that type's doc comment for why.
@main
struct KibbleMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    @State private var isConfirmingSignOut = false
    @State private var isConfirmingSignOutFromSettings = false
    @State private var signOutTarget: AppEnvironment?
    @State private var settingsSignOutTarget: AppEnvironment?
    @State private var editingConversation: ConversationSelection?
    @State private var conversationTarget: AppEnvironment?
    @State private var isAccountPanelOpen = false
    /// The account a Sign Out… or Remove Account… awaits confirmation for,
    /// captured when asked; Settings keeps its own.
    @State private var signingOutAccount: String?
    @State private var removingAccount: String?
    @State private var settingsSigningOutAccount: String?
    // HIG: reopen on the last pane.
    @AppStorage("settingsPane") private var settingsPane = "notifications"

    private var environment: AppEnvironment {
        appDelegate.environment
    }

    var body: some Scene {
        // `Window`, not `WindowGroup`: one window, so `openWindow(id:)` from
        // the menu bar or a notification brings it back rather than making a
        // second one.
        Window("Kibble", id: MainWindow.id) {
            // A stable container, so a phase change swapping the content
            // below is not reported as the window closing and reopening.
            ZStack { content }
                .frame(minWidth: 760, minHeight: 460)
                // Half of the viewing gate (`AppEnvironment.isViewing`); the
                // frontmost half and minimising come from `MacAppDelegate`.
                .onAppear { appDelegate.setMainWindowOpen(true) }
                .onDisappear { appDelegate.setMainWindowOpen(false) }
                // So minimising another window is not read as this one.
                .reportsMainWindow(to: appDelegate)
                .onChange(of: appDelegate.accountHost?.workspace?.selectedID?.rawValue) {
                    editingConversation = nil
                    conversationTarget = nil
                    isConfirmingSignOut = false
                    isConfirmingSignOutFromSettings = false
                    signOutTarget = nil
                    settingsSignOutTarget = nil
                }
                // A confirmation, not a plain button action: an accidental
                // click here costs a full two-factor login, and
                // `AppEnvironment.signOut()`'s own doc comment is where the
                // honesty requirement lives - this dialog only restates it.
                .signOutConfirmation(isPresented: $isConfirmingSignOut) {
                    let target = signOutTarget
                    signOutTarget = nil
                    Task { await target?.signOut() }
                }
                .sheet(item: $editingConversation) { item in
                    ConversationSheetHost(environment: conversationTarget ?? environment, id: item.id)
                }
                .accountConfirmations(
                    signingOut: $signingOutAccount, removing: $removingAccount, host: appDelegate.accountHost
                )
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            // The standard panel, with three short lines about the license as its
            // credits (`AboutPanel`).
            CommandGroup(replacing: .appInfo) {
                Button("About Kibble") {
                    AboutPanel.show()
                }
            }
            // Kibble has no help book, so the Help menu holds the source link and
            // the legal texts (`HelpWindows`).
            CommandGroup(replacing: .help) {
                Button("Kibble on GitHub") {
                    HelpWindows.openSource()
                }
                Divider()
                Button("Disclaimer") {
                    HelpWindows.show(.disclaimer)
                }
                Button("License") {
                    HelpWindows.show(.license)
                }
                Button("Acknowledgments") {
                    HelpWindows.show(.acknowledgments)
                }
            }
            NewConversationCommands(environment: environment)
            AccountCommands(host: appDelegate.accountHost, isPanelOpen: $isAccountPanelOpen) {
                settingsPane = "account"
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    appDelegate.updates.checkNow()
                }
                .disabled(!appDelegate.updates.canCheck)
                Divider()
                Button("Sign Out…") {
                    if appDelegate.accountHost != nil {
                        signingOutAccount = signedInAccount
                    } else {
                        signOutTarget = environment
                        isConfirmingSignOut = true
                    }
                }
                .disabled(appDelegate.accountHost == nil ? !environment.canSignOut : signedInAccount == nil)
            }
            // Search (search spec §1.1): ⌘F, as in Messages, and ⌘G to step.
            CommandGroup(after: .textEditing) {
                Button("Search…") {
                    environment.showSearch()
                }
                .keyboardShortcut("f")
                .disabled(!environment.canSearch)
                Button("Next Result") {
                    environment.stepSearch(1)
                }
                .keyboardShortcut("g")
                .disabled(!environment.canStepSearch)
                Button("Previous Result") {
                    environment.stepSearch(-1)
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(!environment.canStepSearch)
            }
        }

        MenuBarExtra {
            MenuBarContent(
                environment: environment,
                devicePause: appDelegate.accountHost?.deviceNotificationPause
            )
        } label: {
            MenuBarLabel(
                environment: environment,
                aggregateBadgeCount: appDelegate.accountHost?.workspace?.badgeCount,
                accountWindowRequests: appDelegate.accountHost?.workspace?.windowRequests ?? 0
            )
        }
        .menuBarExtraStyle(.menu)

        // HIG for app settings: a toolbar of panes, title following the pane,
        // opened from Kibble › Settings… (⌘,) - all provided by `Settings` and
        // `TabView`. Changes apply as they are made.
        Settings {
            TabView(selection: $settingsPane) {
                Tab("Notifications", systemImage: "bell.badge", value: "notifications") {
                    NotificationSettingsPane(
                        state: environment.notificationSettingsState,
                        actions: environment.notificationSettingsActions(
                            openSystemSettings: { SystemNotificationSettings.open() }
                        )
                    )
                    .frame(width: 560, height: 540)
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
                    ConversationSettingsPane(
                        state: environment.notificationSettingsState,
                        actions: environment.notificationSettingsActions(
                            openSystemSettings: { SystemNotificationSettings.open() }
                        )
                    )
                    .frame(width: 560, height: 420)
                }
                Tab("Sidebar", systemImage: "sidebar.left", value: "sidebar") {
                    SidebarSettingsPane(
                        preferences: environment.sidebarPreferences,
                        update: { environment.updateSidebar($0) }
                    )
                    .frame(width: 560, height: 540)
                }
                Tab("Downloads", systemImage: "arrow.down.circle", value: "downloads") {
                    DownloadSettingsPane(
                        state: environment.downloadSettingsState,
                        actions: environment.downloadSettingsActions
                    )
                    .frame(width: 560, height: 220)
                }
                Tab("Updates", systemImage: "arrow.triangle.2.circlepath", value: "updates") {
                    UpdateSettingsPane(state: appDelegate.updates.state, actions: appDelegate.updates.actions)
                        .frame(width: 560, height: 420)
                }
                Tab("Account", systemImage: "person.crop.circle", value: "account") {
                    AccountSettingsPane(
                        state: environment.accountSettingsState,
                        signOut: settingsSignOut,
                        exportDiagnostics: { appDelegate.diagnostics.export() }
                    )
                    .frame(width: 560, height: 360)
                }
            }
            .signOutConfirmation(isPresented: $isConfirmingSignOutFromSettings) {
                let target = settingsSignOutTarget
                settingsSignOutTarget = nil
                Task { await target?.signOut() }
            }
            .accountConfirmations(
                signingOut: $settingsSigningOutAccount, removing: .constant(nil),
                host: appDelegate.accountHost
            )
        }
    }

    /// The selected account while it is signed in, for Sign Out…; under the
    /// account host, signing out keeps the account rather than removing it.
    private var signedInAccount: String? {
        guard let workspace = appDelegate.accountHost?.workspace, let id = workspace.selectedID,
              workspace.accounts.first(where: { $0.id == id })?.authenticationState == nil
        else { return nil }
        return id.rawValue
    }

    private var settingsSignOut: (() -> Void)? {
        if appDelegate.accountHost != nil {
            return signedInAccount.map { id in { settingsSigningOutAccount = id } }
        }
        return environment.canSignOut ? {
            settingsSignOutTarget = environment
            isConfirmingSignOutFromSettings = true
        } : nil
    }

    @ViewBuilder
    private var content: some View {
        #if DEBUG
            if CommandLine.arguments.contains("--probe=meet-call") {
                MeetDMCallTrialView()
            } else if CommandLine.arguments.contains("--probe=meet-webkit") {
                MeetWebKitProbeView()
            } else {
                normalContent
            }
        #else
            normalContent
        #endif
    }

    @ViewBuilder
    private var normalContent: some View {
        if let host = appDelegate.accountHost {
            AccountWindowContent(
                host: host,
                chatActions: { sceneActions(for: $0, showSettings: $1) },
                isPanelOpen: $isAccountPanelOpen,
                signOutAccount: { signingOutAccount = $0 },
                removeAccount: { removingAccount = $0 },
                manageAccounts: { showSettings in
                    settingsPane = "account"
                    showSettings()
                }
            )
        } else {
            sessionContent
        }
    }

    @ViewBuilder
    private var sessionContent: some View {
        switch environment.phase {
        case .loading:
            ProgressView("Starting…")
        case let .needsSignIn(reason):
            // Explicit, not the default: `.needsSignIn` is the one place
            // there is nothing yet in the Keychain to overwrite, and that
            // fact belongs here rather than in `CookieCaptureView`'s default
            // parameter value.
            // Only without the account host, which signs accounts in itself.
            CookieCaptureView(reason: reason, autoSaveAllowed: true) { await environment.signedIn() }
        case .running, .failed, .report:
            // `.failed` and `.report` draw the same window with an empty
            // sidebar and their message in the status strip. They differ in
            // one thing, and it is `environment.actions`' job: a failed launch
            // offers a way back to sign-in, and a probe report does not.
            SettingsOpening { showSettings in
                ChatWindow(
                    state: environment.sceneState,
                    actions: sceneActions(for: environment, showSettings: showSettings)
                )
            }
        }
    }

    /// `environment.actions` plus what `AppEnvironment` must not own: the
    /// confirmation dialog above already lives in this file, next to the
    /// identical one the menu command has always shown, and `ChatSceneActions
    /// .signOut`'s own doc comment is explicit that triggering *that* dialog -
    /// not a second one - is the whole job here. Settings is the shell's scene,
    /// so the shell opens it (`SettingsOpening`). Assembly, not logic: this
    /// still names no concrete backend and makes no decision `AppEnvironment`
    /// has not already made through `canSignOut`.
    private func sceneActions(
        for target: AppEnvironment,
        showSettings: @escaping () -> Void
    ) -> ChatSceneActions {
        var actions = target.actions
        actions.signOut = target.canSignOut ? { signOutTarget = target; isConfirmingSignOut = true } : nil
        actions.showNotificationSettings = target.canEditNotificationRules
            ? { conversationTarget = target; editingConversation = ConversationSelection(id: $0) }
            : nil
        actions.showSettings = showSettings
        actions.showSidebarSettings = { settingsPane = "sidebar"; showSettings() }
        // The camera is the Mac host's, so the host offers the video call.
        actions.videoCall = appDelegate.videoCall
        return actions
    }
}

/// File › New Message…, New Group Chat… and New Space…, the menu bar's way
/// to what the sidebar's + offers. Each opens the main window first, so the
/// sheet has somewhere to appear.
private struct NewConversationCommands: Commands {
    let environment: AppEnvironment
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Message…") { begin(.message) }
                .keyboardShortcut("n")
                .disabled(!environment.canBeginConversation(.message))
            Button("New Group Chat…") { begin(.groupChat) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!environment.canBeginConversation(.groupChat))
            Button("New Space…") { begin(.space) }
                .disabled(!environment.canBeginConversation(.space))
        }
    }

    private func begin(_ kind: NewConversationKind) {
        openWindow(id: MainWindow.id)
        environment.beginConversation(kind)
    }
}
