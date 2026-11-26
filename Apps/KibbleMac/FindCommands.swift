import AppCore
import DesignSystem
import MacHost
import SwiftUI

/// Edit › Find: Search… on Command-F, and Next Result and Previous Result on
/// Command-G and Shift-Command-G, which step a search's results bar.
///
/// In place of the system's text-editing commands rather than beside them:
/// SwiftUI's `TextEditingCommands` cannot be added without its own Find
/// submenu, whose Find…, Find Next and Find Previous take these same keys and
/// act only on text views that use a find panel, which Kibble's do not.
/// Spelling and Substitutions stay in the composer's own context menu.
///
/// Search… opens the main window first, as File › New Message… does, so
/// the search has somewhere to appear when the window was closed. Stepping
/// acts on the window's results bar and needs that window in front.
struct FindCommands: Commands {
    let environment: AppEnvironment
    @FocusedValue(\.mainWindowCommands) private var window
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .textEditing) {
            Menu("Find", systemImage: MenuBarSymbols.find) {
                Button("Search…") {
                    openWindow(id: MainWindow.id)
                    environment.showSearch()
                }
                .keyboardShortcut(MenuBarShortcuts.search)
                .disabled(!environment.canSearch)
                Button("Next Result") { window?.actions.search?.step(1) }
                    .keyboardShortcut(MenuBarShortcuts.nextResult)
                    .disabled(window?.canStepSearch != true)
                Button("Previous Result") { window?.actions.search?.step(-1) }
                    .keyboardShortcut(MenuBarShortcuts.previousResult)
                    .disabled(window?.canStepSearch != true)
            }
        }
    }
}
