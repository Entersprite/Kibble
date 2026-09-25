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
struct GChatMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    @State private var isConfirmingSignOut = false
    @State private var isConfirmingSignOutFromSettings = false
    @State private var editingConversation: ConversationSelection?
    // HIG: reopen on the last pane.
    @AppStorage("settingsPane") private var settingsPane = "notifications"

    private var environment: AppEnvironment {
        appDelegate.environment
    }

    var body: some Scene {
        // `Window`, not `WindowGroup`: one window, so `openWindow(id:)` from
        // the menu bar or a notification brings it back rather than making a
        // second one.
        Window("GChat", id: MainWindow.id) {
            // A stable container, so a phase change swapping the content
            // below is not reported as the window closing and reopening.
            ZStack { content }
                .frame(minWidth: 760, minHeight: 460)
                // Half of the viewing gate (`AppEnvironment.isViewing`); the
                // frontmost half and minimising come from `MacAppDelegate`.
                .onAppear { environment.setWindowOpen(true) }
                .onDisappear { environment.setWindowOpen(false) }
                // So minimising another window is not read as this one.
                .reportsMainWindow(to: appDelegate)
                // A confirmation, not a plain button action: an accidental
                // click here costs a full two-factor login, and
                // `AppEnvironment.signOut()`'s own doc comment is where the
                // honesty requirement lives - this dialog only restates it.
                .signOutConfirmation(isPresented: $isConfirmingSignOut) {
                    Task { await environment.signOut() }
                }
                .sheet(item: $editingConversation) { item in
                    ConversationNotificationSheet(
                        state: environment.conversationRuleState(for: item.id),
                        update: { environment.settings.update($0, for: .conversation(item.id)) }
                    )
                }
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Divider()
                Button("Sign Out…") {
                    isConfirmingSignOut = true
                }
                .disabled(!environment.canSignOut)
            }
        }

        MenuBarExtra {
            MenuBarContent(environment: environment)
        } label: {
            MenuBarLabel(environment: environment)
        }
        .menuBarExtraStyle(.menu)

        // HIG for app settings: a toolbar of panes, title following the pane,
        // opened from GChat › Settings… (⌘,) - all provided by `Settings` and
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
                Tab("Conversations", systemImage: "bubble.left.and.bubble.right", value: "conversations") {
                    ConversationSettingsPane(
                        state: environment.notificationSettingsState,
                        actions: environment.notificationSettingsActions(
                            openSystemSettings: { SystemNotificationSettings.open() }
                        )
                    )
                    .frame(width: 560, height: 420)
                }
                Tab("Account", systemImage: "person.crop.circle", value: "account") {
                    AccountSettingsPane(
                        state: environment.accountSettingsState,
                        signOut: environment.canSignOut ? { isConfirmingSignOutFromSettings = true } : nil
                    )
                    .frame(width: 560, height: 220)
                }
            }
            .signOutConfirmation(isPresented: $isConfirmingSignOutFromSettings) {
                Task { await environment.signOut() }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch environment.phase {
        case .loading:
            ProgressView("Starting…")
        case let .needsSignIn(reason):
            // Explicit, not the default: `.needsSignIn` is the one place
            // there is nothing yet in the Keychain to overwrite, and that
            // fact belongs here rather than in `CookieCaptureView`'s default
            // parameter value.
            CookieCaptureView(reason: reason, autoSaveAllowed: true) {
                await environment.signedIn()
            }
        case .running, .failed, .report:
            // `.failed` and `.report` draw the same window with an empty
            // sidebar and their message in the status strip. They differ in
            // one thing, and it is `environment.actions`' job: a failed launch
            // offers a way back to sign-in, and a probe report does not.
            ChatWindow(state: environment.sceneState, actions: sceneActions)
        }
    }

    /// `environment.actions` plus the one thing `AppEnvironment` must not own:
    /// the confirmation dialog above already lives in this file, next to the
    /// identical one the menu command has always shown, and `ChatSceneActions
    /// .signOut`'s own doc comment is explicit that triggering *that* dialog -
    /// not a second one - is the whole job here. Assembly, not logic: this
    /// still names no concrete backend and makes no decision `AppEnvironment`
    /// has not already made through `canSignOut`.
    private var sceneActions: ChatSceneActions {
        var actions = environment.actions
        actions.signOut = environment.canSignOut ? { isConfirmingSignOut = true } : nil
        actions.showNotificationSettings = environment.canEditNotificationRules
            ? { editingConversation = ConversationSelection(id: $0) }
            : nil
        return actions
    }
}
