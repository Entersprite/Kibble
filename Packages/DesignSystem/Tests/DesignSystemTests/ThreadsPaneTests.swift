import AppKit
import ChatKit
import SwiftUI
import Testing
@testable import DesignSystem

/// The Threads list's content and its headless list (a `LazyVStack`, not a
/// `List`, so it renders headless like `MentionsPaneList`).
@MainActor
struct ThreadsPaneTests {
    private func item(_ id: String, replies: Int) -> ThreadListItem {
        let root = Message(
            id: Message.ID("m-\(id)"), conversationID: Conversation.ID("space/s-1"),
            threadID: MessageThread.ID(id), sender: Member.ID("u-2"), text: "root \(id)",
            createdAt: Date(timeIntervalSince1970: 1_789_990_000)
        )
        return ThreadListItem(
            root: root,
            thread: MessageThread(
                id: MessageThread.ID(id), conversationID: Conversation.ID("space/s-1"),
                replyCount: replies + 1
            ),
            conversation: Conversation(id: Conversation.ID("space/s-1"), kind: .space, title: "Deploys"),
            directory: [:], me: nil
        )
    }

    @Test func anEmptyListSaysSo() {
        #expect(ThreadsPane.content(items: []) == .empty)
        #expect(ThreadsPane.content(items: [item("t-1", replies: 2)]) == .items)
    }

    @Test func eachItemTakesRoom() {
        func height(_ items: [ThreadListItem]) -> CGFloat {
            NSHostingView(rootView: ThreadsPaneList(items: items, me: nil, now: .now) { _, _ in })
                .fittingSize.height
        }
        let one = height([item("t-1", replies: 2)])
        let two = height([item("t-1", replies: 2), item("t-2", replies: 1)])
        #expect(two > one)
    }
}
