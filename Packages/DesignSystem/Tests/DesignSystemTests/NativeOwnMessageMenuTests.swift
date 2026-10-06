#if os(macOS)
    import AppKit
    import ChatKit
    import Foundation
    import Testing
    @testable import DesignSystem

    /// Edit… and Delete… in the native text menu (edit spec §5): before the
    /// text's own items, only where the rule allows.
    @MainActor
    struct NativeOwnMessageMenuTests {
        private static let me = Member.ID("u-me")

        private static func message(
            sender: Member.ID = me,
            attachments: [ChatKit.Attachment] = []
        ) -> Message {
            Message(
                id: Message.ID("m-1"), conversationID: Conversation.ID("space/s-1"),
                threadID: MessageThread.ID("t-1"), sender: sender, text: "hello",
                createdAt: Date(timeIntervalSince1970: 0), attachments: attachments
            )
        }

        private final class Calls {
            var edits: [Message.ID] = []
            var deletes: [Message.ID] = []
        }

        private static func handlers(_ calls: Calls) -> OwnMessageHandlers {
            OwnMessageHandlers(
                me: me,
                edit: { calls.edits.append($0.id) },
                delete: { calls.deletes.append($0.id) }
            )
        }

        private static func nativeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.addItem(withTitle: "Copy", action: nil, keyEquivalent: "")
            return menu
        }

        private static func titles(_ menu: NSMenu) -> [String] {
            menu.items.map { $0.isSeparatorItem ? "-" : $0.title }
        }

        @Test func myMessageGetsEditAndDeleteBeforeTheNativeItems() {
            let calls = Calls()
            let items = Self.handlers(calls).items(for: Self.message())
            let menu = NativeOwnMessageMenu.insert(items, into: Self.nativeMenu())
            #expect(Self.titles(menu) == ["Edit…", "Delete…", "-", "Copy"])
            for item in menu.items.prefix(2) {
                _ = (item.target as? NSObject)?.perform(item.action, with: item)
            }
            #expect(calls.edits == [Message.ID("m-1")])
            #expect(calls.deletes == [Message.ID("m-1")])
        }

        @Test func someoneElsesMessageGetsNothing() {
            let items = Self.handlers(Calls()).items(for: Self.message(sender: Member.ID("u-other")))
            #expect(items == nil)
            #expect(Self.titles(NativeOwnMessageMenu.insert(items, into: Self.nativeMenu())) == ["Copy"])
        }

        @Test func anAttachmentsMessageGetsDeleteOnly() {
            let file = ChatKit.Attachment(id: "a-1", name: "f.png", contentType: "image/png")
            let items = Self.handlers(Calls()).items(for: Self.message(attachments: [file]))
            let menu = NativeOwnMessageMenu.insert(items, into: Self.nativeMenu())
            #expect(Self.titles(menu) == ["Delete…", "-", "Copy"])
        }

        /// Guard: a backend that cannot edit draws no Edit…, even on mine.
        @Test func withoutAnEditHandlerThereIsNoEditItem() {
            var handlers = Self.handlers(Calls())
            handlers.edit = nil
            let menu = NativeOwnMessageMenu.insert(
                handlers.items(for: Self.message()),
                into: Self.nativeMenu()
            )
            #expect(Self.titles(menu) == ["Delete…", "-", "Copy"])
        }

        /// The full native menu: reactions, then Edit…/Delete…, then the text's.
        @Test func theReactionsStayFirst() {
            let reactions = ReactionActions { _, _, _ in }
            let items = Self.handlers(Calls()).items(for: Self.message())
            let menu = NativeReactionMenu.insertReactions(
                into: NativeOwnMessageMenu.insert(items, into: Self.nativeMenu()),
                message: Self.message(), actions: reactions
            )
            #expect(Self.titles(menu) == ["React", "-", "Edit…", "Delete…", "-", "Copy"])
        }
    }
#endif
