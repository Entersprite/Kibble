import DesignSystem
import SwiftUI

/// The menu bar's Conversation menu (`ConversationMenuBar`): the selected
/// conversation's details, calls and rules, the thread, Mentions and
/// Threads, stepping down the sidebar, and its first nine rows on Command-1
/// to Command-9.
///
/// It acts on the main window that published its commands, and only while
/// that window is in front. With any other window in front the same items
/// stay, disabled, as a Mac app's window commands do; which items are drawn
/// still follows what the selected account's host offers (`offered`).
struct ConversationCommands: Commands {
    /// The selected account's actions, read only while the main window is
    /// not in front, to draw the same items it would offer.
    let offered: () -> ChatSceneActions
    @FocusedValue(\.mainWindowCommands) private var window

    var body: some Commands {
        CommandMenu("Conversation") {
            let actions = window?.actions ?? offered()
            let menu = window?.conversation ?? ConversationMenuBar(state: nil, actions: actions)
            // Dividers rather than `Section`s: a section here is drawn with a
            // separator on each side, two between neighbors and one at each end.
            ForEach(Array(menu.sections.enumerated()), id: \.offset) { index, section in
                if index > 0 {
                    Divider()
                }
                ForEach(section) { entry in
                    ConversationMenuItem(entry: entry, actions: actions)
                }
            }
        }
    }
}

/// One item: a command with its symbol, or a checkmark item for Follow
/// Thread and the listed conversations.
private struct ConversationMenuItem: View {
    let entry: ConversationMenuBar.Entry
    let actions: ChatSceneActions

    var body: some View {
        switch entry.style {
        case let .button(symbol):
            Button(entry.title, systemImage: symbol, action: perform)
                .keyboardShortcut(entry.shortcut)
                .disabled(!entry.isEnabled)
        case let .checkmark(isOn):
            Toggle(entry.title, isOn: Binding(get: { isOn }, set: { _ in perform() }))
                .keyboardShortcut(entry.shortcut)
                .disabled(!entry.isEnabled)
        }
    }

    private func perform() {
        if let command = entry.command {
            ConversationMenuBar.perform(command, actions: actions)
        }
    }
}
