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
            ChatWindow(state: environment.sceneState, actions: environment.actions)
                .frame(minWidth: 760, minHeight: 460)
                .task { await environment.start() }
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
