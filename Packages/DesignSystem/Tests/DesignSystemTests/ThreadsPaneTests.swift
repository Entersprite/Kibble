import AppKit
import ChatKit
import SwiftUI
import Testing
@testable import DesignSystem

/// The Threads list's content and its headless list (a `LazyVStack`, not a
/// `List`, so it renders headless like `MentionsPaneList`).
@MainActor
struct ThreadsPaneTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func item(_ id: String, replies: Int, repliers: [Member.ID] = []) -> ThreadListItem {
        let root = Message(
            id: Message.ID("m-\(id)"), conversationID: Conversation.ID("space/s-1"),
            threadID: MessageThread.ID(id), sender: Member.ID("u-2"), text: "root \(id)",
            createdAt: Date(timeIntervalSince1970: 1_789_990_000)
        )
        return ThreadListItem(
            root: root,
            thread: MessageThread(
                id: MessageThread.ID(id), conversationID: Conversation.ID("space/s-1"),
                replyCount: replies + 1, recentRepliers: repliers
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
            let list = ThreadsPaneList(items: items, me: nil, directory: [:], now: now) { _, _ in }
            return NSHostingView(rootView: list).fittingSize.height
        }
        let one = height([item("t-1", replies: 2)])
        let two = height([item("t-1", replies: 2), item("t-2", replies: 1)])
        #expect(two > one)
    }

    /// The repliers' avatars read the window's directory, as the transcript's
    /// marks do: a replier with a name is drawn with initials, not the glyph
    /// an empty directory leaves (`Avatar`'s rungs). The rows' only other
    /// text is resolved in `ThreadListItem`, so the directory changes the
    /// drawing only through the avatars.
    @Test func aRowDrawsANamedReplierByName() throws {
        let ada = Member.ID("users/ada")
        let named = [ada: Member(id: ada, kind: .human, displayName: "Ada Lovelace")]
        let items = [item("t-1", replies: 2, repliers: [ada])]
        func pixels(_ directory: [Member.ID: Member]) throws -> Data {
            let renderer = ImageRenderer(
                content: ThreadsPaneList(items: items, me: nil, directory: directory, now: now) { _, _ in }
            )
            renderer.scale = 2
            let image = try #require(renderer.cgImage)
            return try #require(image.dataProvider?.data as Data?)
        }
        let withName = try pixels(named)
        let withoutName = try pixels([:])
        // Positive control: a render that drew nothing would match too.
        #expect(withoutName.contains { $0 != 0 })
        #expect(withName != withoutName)
    }
}
