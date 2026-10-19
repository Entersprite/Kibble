import ChatKit
import Foundation
import GRDB
import Testing
@testable import ChatPersistence
@testable import SyncEngine

struct StoreNoOpWriteTests {
    private let space = Conversation.ID("space/noop")
    private let at = Date(timeIntervalSince1970: 1_790_000_000.128263)

    private var message: Message {
        Message(
            id: Message.ID("message/noop"), conversationID: space,
            threadID: MessageThread.ID("thread/noop"), sender: Member.ID("member/noop"),
            text: "hello", createdAt: at,
            reactions: [Reaction(emoji: "👍", count: 1)],
            attachments: [Attachment(id: "asset", name: "photo.png", contentType: "image/png")],
            mentions: [Mention(target: .all, start: 0, length: 5)],
            links: [MessageLink(url: URL(string: "https://example.invalid")!)],
            cards: [AppCard()]
        )
    }

    private func changedRows(_ store: ChatStore) throws -> Int {
        try store.database.read { db in try Int.fetchOne(db, sql: "SELECT total_changes()") ?? 0 }
    }

    @Test func anUnchangedFullOrPartialPagePerformsNoMessageWrites() throws {
        let store = try ChatStore.inMemory()
        let full = message
        try store.apply([.upsertMessage(full)])
        let initial = try changedRows(store)
        var partial = full
        partial.reactions = []
        try store.apply([.upsertMessage(full), .upsertMessageKeepingReactions(partial)])
        #expect(try changedRows(store) == initial)
        #expect(try store.messages(in: space) == [full])
        var edited = full
        edited.text = "changed"
        try store.apply([.upsertMessage(edited)])
        #expect(try changedRows(store) > initial)
        #expect(try store.messages(in: space) == [edited])
    }

    @Test func JSONWhitespaceAndObjectOrderAreNotContentChanges() throws {
        let store = try ChatStore.inMemory()
        let original = message
        try store.apply([.upsertMessage(original)])
        try store.database.write { db in
            try db.execute(
                sql: "UPDATE message SET reactions = ? WHERE id = ?",
                arguments: [
                    "[ { \"emoji\": \"👍\", \"count\": 1, \"includesMe\": false } ]",
                    original.id.rawValue
                ]
            )
        }
        let initial = try changedRows(store)
        try store.apply([.upsertMessage(original)])
        #expect(try changedRows(store) == initial)
        #expect(try store.messages(in: space) == [original])
    }

    @Test func everyMessageFieldCanInvalidateTheStoredValue() throws {
        let original = message
        let variants: [Message] = [
            changing(original) { $0.conversationID = Conversation.ID("space/other") },
            changing(original) { $0.threadID = MessageThread.ID("thread/other") },
            changing(original) { $0.sender = Member.ID("member/other") },
            changing(original) { $0.text = "edited" },
            changing(original) { $0.createdAt = at.addingTimeInterval(1) },
            changing(original) { $0.editedAt = at },
            changing(original) { $0.isDeleted = true },
            changing(original) { $0.reactions[0].includesMe = true },
            changing(original) { $0.attachments[0].thumbnailURL = URL(string: "https://example.invalid/new")
            },
            changing(original) { $0.localID = "echo" },
            changing(original) { $0.mentions[0].mode = .withoutAdding },
            changing(original) { $0.links[0].preview = LinkPreview(title: "new") },
            changing(original) { $0.cards = [] },
            changing(original) { $0.isReply = true }
        ]
        for updated in variants {
            let store = try ChatStore.inMemory()
            try store.apply([.upsertMessage(original)])
            let before = try changedRows(store)
            try store.apply([.upsertMessage(updated)])
            #expect(try changedRows(store) > before)
            let actual = try store.database.read { db in
                try MessageRow.fetchOne(db, key: updated.id.rawValue)?.message
            }
            #expect(actual == updated)
        }
    }

    @Test func anEqualServerEchoStillRemovesAnOptimisticDuplicate() throws {
        let store = try ChatStore.inMemory()
        var server = message
        server.localID = "send/1"
        var optimistic = server
        optimistic.id = Message.ID("local/send/1")
        try store.apply([.upsertMessage(server), .insertMessageIfAbsent(optimistic)])
        #expect(try store.messages(in: space).count == 2)
        try store.apply([.upsertMessage(server)])
        #expect(try store.messages(in: space) == [server])
    }

    @Test func repeatedReactionAndDeletionUpdatesAreQuietButRealChangesLand() throws {
        let store = try ChatStore.inMemory()
        let original = message
        try store.apply([.upsertMessage(original)])
        let initial = try changedRows(store)
        try store.apply([.setReactions(messageID: original.id, reactions: original.reactions)])
        #expect(try changedRows(store) == initial)
        try store.apply([.setReactions(messageID: original.id, reactions: [])])
        #expect(try changedRows(store) > initial)
        try store.apply([.markMessageDeleted(id: original.id, in: space)])
        let deleted = try changedRows(store)
        try store.apply([.markMessageDeleted(id: original.id, in: space)])
        #expect(try changedRows(store) == deleted)
        #expect(try store.messages(in: space).first?.isDeleted == true)
    }

    @Test func anUnchangedWorldPreservesMembershipAndPerformsNoRowChanges() throws {
        let store = try ChatStore.inMemory()
        let member = Member.ID("member/noop")
        let conversation = Conversation(
            id: space, kind: .space, lastActivity: at, members: [member],
            readPosition: at, historyClearedBefore: at.addingTimeInterval(-1)
        )
        try store.apply([
            .upsertMembers([Member(id: member, kind: .human)]), .replaceConversations([conversation])
        ])
        let initial = try changedRows(store)
        try store.apply([.replaceConversations([conversation])])
        #expect(try changedRows(store) == initial)
        var changed = conversation
        changed.markedUnreadAt = at
        changed.hasUnread = true
        try store.apply([.replaceConversations([changed])])
        #expect(try changedRows(store) > initial)
        #expect(try store.conversations() == [changed])
    }

    @Test func replayingAClearCutoffStillRemovesLateOrphanedThreadMetadata() throws {
        let store = try ChatStore.inMemory()
        let conversation = Conversation(id: space, kind: .space, historyClearedBefore: at)
        try store.apply([.upsertConversation(conversation)])
        try store.apply([.applyThreadChange(
            thread: MessageThread.ID("late/thread"), conversation: space, change: .followed(true)
        )])
        let before = try store.database
            .read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM thread") }
        #expect(before == 1)
        try store.apply([.upsertConversation(conversation)])
        let after = try store.database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM thread") }
        #expect(after == 0)
        #expect(try store.conversations() == [conversation])
    }

    private func changing(_ message: Message, _ change: (inout Message) -> Void) -> Message {
        var changed = message
        change(&changed)
        return changed
    }
}
