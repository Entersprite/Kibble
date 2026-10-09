#if os(macOS)
    import AppKit
    import ChatKit
    import Foundation
    import Testing
    @testable import DesignSystem

    /// "Reply in Thread" on a top-level message with no replies, "Mark as
    /// Unread" on a reply, in both menus (threads spec §5).
    @MainActor
    struct ThreadMenuItemsTests {
        private static let me = Member.ID("u-me")

        private static func message(
            id: String = "m-1", sender: Member.ID = Member.ID("u-2"), isReply: Bool = false,
            isDeleted: Bool = false
        ) -> Message {
            Message(
                id: Message.ID(id), conversationID: Conversation.ID("space/s-1"),
                threadID: MessageThread.ID("t-1"), sender: sender, text: "hello",
                createdAt: Date(timeIntervalSince1970: 0), isDeleted: isDeleted, isReply: isReply
            )
        }

        private final class Calls {
            var replies: [Message.ID] = []
            var unread: [Message.ID] = []
        }

        private static func handlers(_ calls: Calls, hasReplies: Bool = false) -> OwnMessageHandlers {
            OwnMessageHandlers(
                me: me,
                edit: nil,
                delete: nil,
                replyInThread: { calls.replies.append($0.id) },
                markUnread: { calls.unread.append($0.id) },
                hasReplies: { _ in hasReplies }
            )
        }

        @Test func aTopLevelMessageWithoutRepliesOffersReplyInThread() throws {
            let calls = Calls()
            let items = try #require(Self.handlers(calls).items(for: Self.message()))
            items.replyInThread?()
            #expect(calls.replies == [Message.ID("m-1")])
            #expect(items.markUnread == nil)
        }

        /// The mark opens a thread that has replies; the menu item would only
        /// say the same thing again.
        @Test func aMessageWithRepliesDoesNotOfferIt() {
            let calls = Calls()
            #expect(Self.handlers(calls, hasReplies: true).items(for: Self.message()) == nil)
        }

        @Test func aReplyOffersMarkAsUnreadOnly() throws {
            let calls = Calls()
            let items = try #require(Self.handlers(calls).items(for: Self.message(isReply: true)))
            #expect(items.replyInThread == nil)
            items.markUnread?()
            #expect(calls.unread == [Message.ID("m-1")])
        }

        /// A tombstone and a reply still sending (`local/`) have nothing to
        /// reply to or mark.
        @Test func aDeletedOrSendingMessageOffersNeither() {
            let calls = Calls()
            #expect(Self.handlers(calls).items(for: Self.message(isDeleted: true)) == nil)
            #expect(Self.handlers(calls).items(for: Self.message(id: "local/1", isReply: true)) == nil)
        }

        @Test func theNativeMenuPutsThemFirst() {
            let calls = Calls()
            let menu = NSMenu()
            menu.addItem(withTitle: "Copy", action: nil, keyEquivalent: "")
            let mine = OwnMessageHandlers(
                me: Self.me, edit: { _ in }, delete: { _ in },
                replyInThread: { calls.replies.append($0.id) }, markUnread: nil, hasReplies: { _ in false }
            )
            let result = NativeOwnMessageMenu.insert(
                mine.items(for: Self.message(sender: Self.me)), into: menu
            )
            let titles = result.items.map { $0.isSeparatorItem ? "-" : $0.title }
            #expect(titles == ["Reply in Thread", "Edit…", "Delete…", "-", "Copy"])
        }
    }
#endif
