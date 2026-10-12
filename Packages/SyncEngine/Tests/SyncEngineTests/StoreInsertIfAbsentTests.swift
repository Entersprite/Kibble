import ChatKit
import Foundation
import Testing
@testable import SyncEngine

/// The write an opened search hit is stored with. A hit lacks what history
/// carries - reactions, the edit time, app cards, some link-preview fields -
/// and its upload token differs (`findings.md` §65.8), so it may add a
/// message the store lacks and must never replace one it holds.
struct StoreInsertIfAbsentTests {
    private static let conversation = Conversation.ID("space/s-1")
    /// No whole millisecond, so a lossy write would show.
    private static let createdAt = Date(timeIntervalSince1970: 1_790_123_456.789_012)
    private static let doc = MessageLink(
        url: URL(string: "https://acme.example/doc")!, start: 0, length: 3,
        preview: LinkPreview(title: "Doc", domain: "acme.example")
    )

    private static func hit(_ id: String = "m-1") -> Message {
        Message(
            id: Message.ID(id), conversationID: conversation, threadID: MessageThread.ID("t-1"),
            sender: Member.ID("u-1"), text: "deploy from search", createdAt: createdAt,
            attachments: [Attachment(id: "hit-token", name: "log.txt", contentType: "text/plain")],
            links: [MessageLink(url: URL(string: "https://acme.example/doc")!, start: 0, length: 3)],
            isReply: true
        )
    }

    /// History's copy of the same message: everything a hit lacks.
    private static func historyCopy() -> Message {
        var message = hit()
        message.text = "deploy, edited"
        message.editedAt = createdAt.addingTimeInterval(60)
        message.reactions = [Reaction(emoji: "👍", count: 2)]
        message.attachments = [Attachment(id: "history-token", name: "log.txt", contentType: "text/plain")]
        message.links = [doc]
        message.cards = [AppCard(header: AppCard.Header(title: RichText("Deploy finished")))]
        return message
    }

    private func stored(_ store: ChatStore, _ id: String = "m-1") throws -> Message? {
        try store.message(Message.ID(id))
    }

    @Test func aMissingMessageIsInsertedWhole() throws {
        let store = try ChatStore.inMemory()
        try store.apply([.insertMessageIfAbsent(Self.hit())])
        #expect(try stored(store) == Self.hit())
    }

    @Test func aStoredCopyIsLeftUntouched() throws {
        let store = try ChatStore.inMemory()
        try store.apply([.upsertMessage(Self.historyCopy())])
        try store.apply([.insertMessageIfAbsent(Self.hit())])
        #expect(try stored(store) == Self.historyCopy())
    }

    /// A tombstone stays one: a hit for a message deleted since must not
    /// bring its text back.
    @Test func aTombstoneStaysDeleted() throws {
        let store = try ChatStore.inMemory()
        try store.apply([
            .upsertMessage(Self.historyCopy()),
            .markMessageDeleted(id: Message.ID("m-1"), in: Self.conversation)
        ])
        try store.apply([.insertMessageIfAbsent(Self.hit())])
        let row = try #require(try stored(store))
        #expect(row.isDeleted)
        #expect(row.text.isEmpty)
    }

    /// The hit does not lock its row: a later write of the same message - a
    /// push, or a newest page that holds it - replaces it as it would any.
    @Test func historyLaterReplacesTheHit() throws {
        let store = try ChatStore.inMemory()
        try store.apply([.insertMessageIfAbsent(Self.hit())])
        try store.apply([.upsertMessage(Self.historyCopy())])
        #expect(try stored(store) == Self.historyCopy())
    }

    /// One statement, no read first: a copy written earlier in the same
    /// transaction (as a push between a check and a write would be) wins.
    @Test func aCopyWrittenEarlierInTheSameBatchWins() throws {
        let store = try ChatStore.inMemory()
        try store.apply([.upsertMessage(Self.historyCopy()), .insertMessageIfAbsent(Self.hit())])
        #expect(try stored(store) == Self.historyCopy())
    }
}
