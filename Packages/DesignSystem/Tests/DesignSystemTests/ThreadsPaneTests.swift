import AppKit
import ChatKit
import SwiftUI
import Testing
@testable import DesignSystem

/// The Threads list's content, its rows, and the list a click selects in and
/// Return opens from.
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

    /// The context menu and Return act on one thread; several, none, or one
    /// the list no longer holds is nothing to open.
    @Test func oneSelectedThreadIsWhatOpens() {
        let items = [item("t-1", replies: 2), item("t-2", replies: 1)]
        #expect(PaneSelection.single([items[1].id], in: items)?.thread.id == MessageThread.ID("t-2"))
        #expect(PaneSelection.single([], in: items) == nil)
        #expect(PaneSelection.single(Set(items.map(\.id)), in: items) == nil)
        let gone = ThreadListItem.Key(
            conversation: Conversation.ID("space/s-1"),
            thread: MessageThread.ID("t-9")
        )
        #expect(PaneSelection.single([gone], in: items) == nil)
    }

    /// The repliers' avatars read the window's directory, as the transcript's
    /// marks do: a replier with a name is drawn with initials, not the glyph
    /// an empty directory leaves (`Avatar`'s rungs). The rows' only other
    /// text is resolved in `ThreadListItem`, so the directory changes the
    /// drawing only through the avatars.
    @Test func aRowDrawsANamedReplierByName() throws {
        let ada = Member.ID("users/ada")
        let named = [ada: Member(id: ada, kind: .human, displayName: "Ada Lovelace")]
        let row = item("t-1", replies: 2, repliers: [ada])
        func pixels(_ directory: [Member.ID: Member]) throws -> Data {
            let renderer = ImageRenderer(
                content: ThreadItemRow(item: row, me: nil, directory: directory, now: now).frame(width: 420)
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

    /// A native list: one row per followed thread, a selected row does not
    /// open by being selected, and Return opens the selected one.
    @Test func returnOpensTheSelectedThreadInANativeList() throws {
        let items = [item("t-1", replies: 2), item("t-2", replies: 1), item("t-3", replies: 4)]
        var opened: [MessageThread.ID] = []
        let pane = try HostedList(ThreadsPane(items: items, me: nil, directory: [:]) { _, thread in
            opened.append(thread)
        })
        defer { pane.close() }
        #expect(pane.selectableRows.count == items.count)
        try pane.select(row: pane.selectableRows[1])
        #expect(opened.isEmpty)
        try pane.pressReturn()
        #expect(opened == [MessageThread.ID("t-2")])
    }
}
