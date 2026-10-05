#if os(macOS)
    import AppKit
    import ChatKit
    import Foundation
    import Testing
    @testable import DesignSystem

    /// `NativeReactionMenu`: the reaction row added to the native text menu
    /// (native text menu spec §2), and `QuickReactionItems`, the description
    /// both menus are built from.
    @MainActor
    struct NativeReactionMenuTests {
        private final class Toggles {
            var calls: [(Message.ID, String, Bool)] = []
        }

        private static func message(reactions: [Reaction] = [], isDeleted: Bool = false) -> Message {
            Message(
                id: Message.ID("m-1"), conversationID: Conversation.ID("space/s-1"),
                threadID: MessageThread.ID("t-1"), sender: Member.ID("u-1"), text: "hello",
                createdAt: Date(timeIntervalSince1970: 0), isDeleted: isDeleted, reactions: reactions
            )
        }

        private static func actions(_ toggles: Toggles) -> ReactionActions {
            ReactionActions { id, choice, add in toggles.calls.append((id, choice.emoji, add)) }
        }

        /// What `NSTextView` hands its delegate: a menu with items of its own.
        private static func nativeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.addItem(withTitle: "Look Up", action: nil, keyEquivalent: "")
            menu.addItem(withTitle: "Copy", action: nil, keyEquivalent: "")
            return menu
        }

        @Test func theItemsFollowTheQuickSetAndKnowWhatIsMine() {
            let items = QuickReactionItems.items(for: [Reaction(emoji: "👍", count: 2, includesMe: true)])
            #expect(items.map(\.emoji) == QuickReactions.defaults)
            #expect(items.first?.adds == false)
            let restAdd = items.dropFirst().allSatisfy { $0.adds }
            #expect(restAdd)
        }

        @Test func thePaletteComesFirstThenASeparatorThenTheNativeItems() throws {
            let menu = NativeReactionMenu.insertReactions(
                into: Self.nativeMenu(), message: Self.message(), actions: Self.actions(Toggles())
            )
            let palette = try #require(menu.items.first?.submenu)
            #expect(palette.presentationStyle == .palette)
            #expect(palette.items.map(\.title) == QuickReactions.defaults)
            #expect(palette.items.allSatisfy { $0.image != nil })
            #expect(menu.items.count == 4)
            #expect(menu.items[1].isSeparatorItem)
            #expect(menu.items.dropFirst(2).map(\.title) == ["Look Up", "Copy"])
        }

        /// Review Focus 2: the item's target is weak, so it must survive the
        /// builder returning. Both directions of the toggle.
        @Test func choosingAnItemTogglesTheRightReaction() throws {
            let toggles = Toggles()
            let mine = [Reaction(emoji: "👍", count: 1, includesMe: true)]
            let menu = NativeReactionMenu.insertReactions(
                into: Self.nativeMenu(), message: Self.message(reactions: mine), actions: Self.actions(toggles)
            )
            let palette = try #require(menu.items.first?.submenu)
            for index in [0, 1] {
                let item = palette.items[index]
                let target = try #require(item.target as? NSObject)
                let action = try #require(item.action)
                _ = target.perform(action, with: item)
            }
            #expect(toggles.calls.map(\.0) == [Message.ID("m-1"), Message.ID("m-1")])
            #expect(toggles.calls.map(\.1) == ["👍", "❤️"])
            #expect(toggles.calls.map(\.2) == [false, true])
        }

        @Test func withoutActionsTheNativeMenuIsUntouched() {
            let menu = NativeReactionMenu.insertReactions(
                into: Self.nativeMenu(), message: Self.message(), actions: nil
            )
            #expect(menu.items.map(\.title) == ["Look Up", "Copy"])
        }

        @Test func aDeletedMessageOffersNoReactions() {
            let menu = NativeReactionMenu.insertReactions(
                into: Self.nativeMenu(), message: Self.message(isDeleted: true), actions: Self.actions(Toggles())
            )
            #expect(menu.items.map(\.title) == ["Look Up", "Copy"])
        }
    }
#endif
