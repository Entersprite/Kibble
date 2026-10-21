import SwiftUI

/// What the main window offers the menu bar while it is in front.
///
/// The host publishes it with `focusedSceneValue` beside the `ChatWindow` it
/// draws, from the same state and actions, so the menu bar acts on the
/// window's own account and nothing else. The commands that act on a
/// window read it with `@FocusedValue`: while the main window is not in
/// front (closed, minimized, or another window is key) there is none, and
/// they are disabled, as a Mac app's window commands are.
///
/// Equal while it comes from the same source with the same menu: a new value
/// on every render would rebuild the menu bar each time, and the actions act
/// on that source's current state whichever render they came from. `scope`
/// names the source (the host's session object), so a new session for the
/// same account, whose old actions would do nothing, is never taken for the
/// old one.
public struct MainWindowCommands: Equatable {
    public let scope: AnyHashable
    public let conversation: ConversationMenuBar
    /// Edit › Find › Next Result and Previous Result: a search's results bar
    /// is up and its overlay is not, the session model's own rule.
    public let canStepSearch: Bool
    public let actions: ChatSceneActions

    @MainActor
    public init(scope: AnyHashable, state: ChatSceneState, actions: ChatSceneActions) {
        self.scope = scope
        conversation = ConversationMenuBar(state: state, actions: actions)
        canStepSearch = actions.search != nil && state.search.bar != nil && !state.search.isShown
        self.actions = actions
    }

    public static func == (lhs: MainWindowCommands, rhs: MainWindowCommands) -> Bool {
        lhs.scope == rhs.scope && lhs.conversation == rhs.conversation
            && lhs.canStepSearch == rhs.canStepSearch
    }
}

public extension FocusedValues {
    @Entry var mainWindowCommands: MainWindowCommands?
}
