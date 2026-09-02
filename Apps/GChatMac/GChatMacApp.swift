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

    var body: some Scene {
        WindowGroup {
            content
                .frame(minWidth: 760, minHeight: 460)
                .task { await environment.start() }
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }

    @ViewBuilder
    private var content: some View {
        switch environment.phase {
        case .loading:
            ProgressView("Starting…")
        case let .needsSignIn(reason):
            CookieCaptureView(reason: reason) {
                await environment.signedIn()
            }
        case .running, .failed, .report:
            // `.failed` and `.report` draw the same window with an empty
            // sidebar and their message in the status strip. They differ in
            // one thing, and it is `environment.actions`' job: a failed launch
            // offers a way back to sign-in, and a probe report does not.
            ChatWindow(state: environment.sceneState, actions: environment.actions)
        }
    }
}
