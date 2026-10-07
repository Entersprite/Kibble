import ChatKit
import Foundation
import Testing
@testable import SyncEngine

/// Links and cards in the store (links spec §5).
struct StoreLinksCardsTests {
    private let conversation = Conversation(id: Conversation.ID("space/s"), kind: .space)
    private static let doc = MessageLink(url: URL(string: "https://acme.example/doc")!, start: 0, length: 3)
    private static let card = AppCard(header: AppCard.Header(title: RichText("Deploy finished")))

    private func message(
        text: String = "doc", links: [MessageLink], cards: [AppCard], reactions: [Reaction] = []
    ) -> Message {
        Message(
            id: Message.ID("m:1"), conversationID: conversation.id, threadID: MessageThread.ID("t"),
            sender: Member.ID("users/alice"), text: text,
            createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            reactions: reactions, links: links, cards: cards
        )
    }

    private func stored(_ store: ChatStore) throws -> Message? {
        try store.messages(in: conversation.id).first
    }

    @Test func linksAndCardsSurviveTheStore() throws {
        let store = try ChatStore.inMemory()
        try store.apply([
            .replaceConversations([conversation]),
            .upsertMessage(message(links: [Self.doc], cards: [Self.card]))
        ])
        #expect(try stored(store)?.links == [Self.doc])
        #expect(try stored(store)?.cards == [Self.card])
    }

    @Test func aRowWrittenBeforeV10ReadsAsNone() throws {
        let store = try ChatStore.inMemory()
        try store.apply([.replaceConversations([conversation])])
        try store.database.write { db in
            try db.execute(sql: """
            INSERT INTO message (id, conversationID, threadID, sender, text, createdAt, isDeleted,
                                 reactions, attachments)
            VALUES ('m:old', 'space/s', 't', 'users/alice', 'hi', ?, 0, '[]', '[]')
            """, arguments: [StoredDate.value(Date(timeIntervalSince1970: 1_790_000_000))])
        }
        #expect(try stored(store)?.links == [])
        #expect(try stored(store)?.cards == [])
    }

    /// Review Focus 5: an edit or app update replaces both, even through the
    /// push path that keeps reactions.
    @Test func aPushReplacesLinksAndCardsWhileKeepingReactions() throws {
        let store = try ChatStore.inMemory()
        let thumbs = [Reaction(emoji: "👍", count: 1)]
        try store.apply([
            .replaceConversations([conversation]),
            .upsertMessage(message(links: [Self.doc], cards: [Self.card], reactions: thumbs))
        ])
        try store.apply([.upsertMessageKeepingReactions(message(text: "edited", links: [], cards: []))])
        let row = try #require(try stored(store))
        #expect(row.links == [])
        #expect(row.cards == [])
        #expect(row.reactions == thumbs)
    }

    @Test func aTombstoneClearsLinksAndCards() throws {
        let store = try ChatStore.inMemory()
        try store.apply([
            .replaceConversations([conversation]),
            .upsertMessage(message(links: [Self.doc], cards: [Self.card]))
        ])
        try store.apply([.markMessageDeleted(id: Message.ID("m:1"), in: conversation.id)])
        let row = try #require(try stored(store))
        #expect(row.isDeleted)
        #expect(row.links == [])
        #expect(row.cards == [])
    }
}
