import AppCore
import ChatKit
import DesignSystem
import SwiftUI

/// The shell.
///
/// Everything this file does is assemble packages and hand the window a model.
/// There is deliberately no logic here: CLAUDE.md's structure rule is that the
/// app target is a shell so that `sourcekit-lsp` and `swift test` keep working
/// without Xcode, and so that a second app - iOS, later - assembles the same
/// pieces rather than reimplementing them.
@main
struct GChatMacApp: App {
    @State private var environment = AppEnvironment()
    @State private var isConfirmingSignOut = false

    var body: some Scene {
        WindowGroup {
            content
                .frame(minWidth: 760, minHeight: 460)
                .task { await environment.start() }
                // A confirmation, not a plain button action: an accidental
                // click here costs a full two-factor login, and
                // `AppEnvironment.signOut()`'s own doc comment is where the
                // honesty requirement lives - this dialog only restates it.
                .confirmationDialog(
                    "Sign out of GChat?",
                    isPresented: $isConfirmingSignOut,
                    titleVisibility: .visible
                ) {
                    Button("Sign Out", role: .destructive) {
                        Task { await environment.signOut() }
                    }
                } message: {
                    Text(
                        "This Mac will forget your account and its local history. " +
                            "This does not sign you out of Google - your session " +
                            "stays valid there until it expires on its own."
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
        return actions
    }
}
