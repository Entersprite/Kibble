import AppKit
import ChatKit
import SwiftUI
import Testing
@testable import DesignSystem

/// The mark sits under every message. With nothing to draw it must be no view
/// at all, or every bubble gains a stack's spacing (`CLAUDE.md`: an empty
/// view still takes a stack's spacing).
@MainActor
struct ThreadMarkLayoutTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let message = Message(
        id: Message.ID("m-1"), conversationID: Conversation.ID("space/s-1"),
        threadID: MessageThread.ID("t-1"), sender: Member.ID("u-1"), text: "hello",
        createdAt: Date(timeIntervalSince1970: 1_789_990_000)
    )

    private func thread(messages: Int) -> MessageThread {
        MessageThread(
            id: MessageThread.ID("t-1"), conversationID: Conversation.ID("space/s-1"),
            replyCount: messages, lastActivity: now,
            recentRepliers: [Member.ID("u-2"), Member.ID("u-3")]
        )
    }

    /// The mark under `message` (or `on`), at the fixed clock.
    private func mark(
        _ thread: MessageThread?, on other: Message? = nil, open: (() -> Void)? = {}
    ) -> ThreadMark? {
        ThreadMark(thread: thread, message: other ?? message, directory: [:], now: now, open: open)
    }

    private func height(_ view: some View) -> CGFloat {
        NSHostingView(rootView: view).fittingSize.height
    }

    @Test func noRepliesNoThreadNoActionOrAReplyIsNoMark() {
        #expect(mark(thread(messages: 1)) == nil)
        #expect(mark(nil) == nil)
        #expect(mark(thread(messages: 3), open: nil) == nil)
        var reply = message
        reply.isReply = true
        #expect(mark(thread(messages: 3), on: reply) == nil)
        #expect(mark(thread(messages: 3)) != nil)
    }

    /// A deleted first message keeps its thread reachable: the tombstone
    /// still gets the mark (Review Focus 1).
    @Test func aDeletedFirstMessageKeepsItsMark() {
        var deleted = message
        deleted.isDeleted = true
        #expect(mark(thread(messages: 3), on: deleted) != nil)
    }

    /// The bubble's own stack, with and without a mark that is not there.
    @Test func aMessageWithoutRepliesIsAsTallAsBefore() {
        let bare = height(VStack(spacing: 2) { Text("hello") })
        let withNone = height(VStack(spacing: 2) {
            Text("hello")
            if let mark = mark(thread(messages: 1)) {
                mark
            }
        })
        #expect(withNone == bare)
    }

    /// The server's count can say replies the store holds none of. With no
    /// repliers the label is its words alone: no room kept for avatars.
    @Test func aThreadWithNoRepliersKeepsNoRoomForAvatars() {
        let unseen = MessageThread(
            id: MessageThread.ID("t-1"), conversationID: Conversation.ID("space/s-1"), replyCount: 3
        )
        let label = NSHostingView(rootView: ThreadMarkLabel(thread: unseen, directory: [:], now: now))
        let words = NSHostingView(rootView: Text(ThreadMarkText.count(unseen))
            .font(.caption.weight(.regular)))
        #expect(label.fittingSize.width == words.fittingSize.width)
        // Positive control: with repliers the label is wider than its words.
        let seen = NSHostingView(rootView: ThreadMarkLabel(
            thread: thread(messages: 3),
            directory: [:],
            now: now
        ))
        #expect(seen.fittingSize.width > words.fittingSize.width)
    }

    @Test func aMessageWithRepliesIsTaller() {
        let bare = height(VStack(spacing: 2) { Text("hello") })
        let marked = height(VStack(spacing: 2) {
            Text("hello")
            if let mark = mark(thread(messages: 3)) {
                mark
            }
        })
        #expect(marked > bare)
    }
}
