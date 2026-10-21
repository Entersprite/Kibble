#if os(macOS)
    import AppKit
    import ChatKit
    import Testing
    @testable import DesignSystem

    /// An SF Symbol name is an unchecked string: a wrong one renders as empty
    /// space (`CLAUDE.md`). Every symbol the sidebar, its row menu and the
    /// Set a Status sheet use is checked.
    @MainActor
    struct SidebarSymbolTests {
        private let actions: [ConversationAction] = [.markUnread, .leave, .hide, .block, .delete]

        private var rowMenuItems: [ConversationMenu.Item] {
            [.call, .markAsRead, .mute, .unmute, .notificationSettings] + actions.map { .action($0) }
        }

        @Test func everySymbolExists() {
            let names = rowMenuItems.map(\.symbol) + FavoriteMenu.symbols + [
                SidebarPinned.searchSymbol, SidebarPinned.mentionsSymbol, SidebarRowPicture.spaceSymbol,
                SetStatusSheet.emojiSymbol
            ]
            for name in names {
                #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
            }
        }

        /// The row menu's items each have their own symbol: none is left to
        /// the `unknown` fallback, and no two items share one.
        @Test func eachRowMenuItemHasItsOwnSymbol() {
            let symbols = rowMenuItems.map(\.symbol)
            #expect(Set(symbols).count == symbols.count)
            #expect(!symbols.contains(ConversationAction.unknown("").menuSymbol))
            #expect(ConversationMenu.Item.call.symbol == "phone")
            #expect(ConversationMenu.Item.action(.delete).symbol == "trash")
        }

        @Test func favoritesAddWithAStarAndRemoveWithAStruckOutOne() {
            let target = SidebarSelection.conversation(Conversation.ID("dm/1"))
            let added = FavoriteMenu.toggling(target, in: SidebarPreferences())
            #expect(FavoriteMenu.item(for: target, in: SidebarPreferences()) == ("Add to Favorites", "star"))
            #expect(FavoriteMenu.item(for: target, in: added) == ("Remove from Favorites", "star.slash"))
        }
    }
#endif
