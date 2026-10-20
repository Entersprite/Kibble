import ChatKit
import SwiftUI

/// Search's place in the window (search spec §1). Its own file so
/// `ChatWindow.swift` stays under `file_length`.
extension ChatWindow {
    /// Over the whole split view, below the toolbar's band: content in the
    /// band takes no clicks (CLAUDE.md, session 63).
    @ViewBuilder var searchOverlay: some View {
        if state.search.isShown, let search = actions.search {
            SearchOverlay(state: state, actions: search)
                // Each account's own query: the field's text is the view's.
                .id(state.accountID)
        }
    }
}
