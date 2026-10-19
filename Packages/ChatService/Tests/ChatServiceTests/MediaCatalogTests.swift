import ChatAPI
import ChatKit
import ChatService
import Foundation
import GRDB
import Testing
@testable import ChatServiceStorage

@Suite(.timeLimit(.minutes(1)))
struct MediaCatalogTests {
    let conversation = Conversation.ID("conversation")
    let messageID = Message.ID("message")
    let image = URL(string: "https://images.example/issued.png")!
    let cardImage = URL(string: "https://images.example/card.png")!
    let attachment = Attachment(
        id: "issued-attachment",
        name: "file",
        contentType: "application/octet-stream"
    )

    func message(_ index: Int? = nil) -> Message {
        Message(
            id: index.map { .init("message-\($0)") } ?? messageID, conversationID: conversation,
            threadID: .init("thread"), sender: .init("sender"), text: "Message",
            createdAt: Date(timeIntervalSince1970: Double(index ?? 10)),
            reactions: [Reaction(
                emoji: ":demo:",
                count: 1,
                customEmoji: .init(id: "emoji", shortcode: "demo", imageToken: "issued")
            )],
            attachments: [index
                .map { Attachment(id: "media-\($0)", name: "file", contentType: "text/plain") } ??
                attachment],
            links: [MessageLink(
                url: URL(string: "https://site.example/page")!,
                preview: .init(title: "Preview", imageURL: image)
            )],
            cards: [AppCard(sections: [.init(widgets: [.image(.init(url: cardImage))])])]
        )
    }

    func store() throws -> SQLiteAccountStorage {
        let store = try SQLiteAccountStorage(account: .init("account"), path: ":memory:")
        _ = try store.append(
            .conversationsChanged([Conversation(id: conversation, kind: .space)]),
            live: false
        )
        return store
    }

    @Test func onlyIssuedMediaResolvesAndTheCatalogIsAccountScoped() throws {
        let first = try store()
        _ = try first.append(.messageReceived(message()), live: true)
        let issued = try #require(first.mediaSources(for: .attachment(attachment.id), at: Date()).first)
        #expect(issued.origin == .message(conversation, messageID))
        #expect(issued.source == .attachment(attachment))
        #expect(try first.mediaSources(for: .customEmoji("emoji"), at: Date()).count == 1)
        #expect(try first.mediaSources(for: .remoteImage(image), at: Date()).count == 1)
        #expect(try first.mediaSources(for: .remoteImage(cardImage), at: Date()).count == 1)
        #expect(try first.mediaSources(
            for: .remoteImage(#require(URL(string: "https://site.example/page"))),
            at: Date()
        ).isEmpty)
        #expect(try first.mediaSources(for: .attachment("forged"), at: Date()).isEmpty)
        #expect(try store().mediaSources(for: .attachment(attachment.id), at: Date()).isEmpty)
    }

    @Test func unchangedFactsStayValidButUpdatesDeletionAndConversationRemovalRevokeOldHandles() throws {
        let store = try store()
        var value = message()
        _ = try store.append(.messageReceived(value), live: true)
        let old = try #require(store.mediaSources(for: .attachment(attachment.id), at: Date()).first)
        _ = try store.append(.messageUpdated(value), live: true)
        #expect(try store.isCurrentMediaSource(old, at: Date()))
        value.attachments[0].name = "Changed"
        _ = try store.append(.messageUpdated(value), live: true)
        #expect(try !store.isCurrentMediaSource(old, at: Date()))
        let changed = try #require(store.mediaSources(for: .attachment(attachment.id), at: Date()).first)
        _ = try store.append(.messageDeleted(id: messageID, in: conversation), live: true)
        #expect(try !store.isCurrentMediaSource(changed, at: Date()))
        #expect(try store.mediaSources(for: .attachment(attachment.id), at: Date()).isEmpty)
        _ = try store.append(.messageReceived(message()), live: true)
        let restored = try #require(store.mediaSources(for: .attachment(attachment.id), at: Date()).first)
        try store.rememberQueryMedia([message(7)], at: Date())
        let preview = try #require(store.mediaSources(for: .attachment("media-7"), at: Date()).first)
        _ = try store.append(
            .conversationRemoved(conversationID: conversation, historyBefore: nil),
            live: true
        )
        #expect(try !store.isCurrentMediaSource(restored, at: Date()))
        _ = try store.append(
            .conversationsChanged([Conversation(
                id: conversation, kind: .space, latestMainMessageAt: Date(timeIntervalSince1970: 30)
            )]), live: false
        )
        #expect(try store.conversation(conversation) != nil)
        #expect(try !store.isCurrentMediaSource(restored, at: Date()))
        #expect(try !store.isCurrentMediaSource(preview, at: Date()))
    }

    @Test func journalFailureRollsBackReferenceAuthorityAndItsVersion() throws {
        let store = try store()
        var value = message()
        _ = try store.append(.messageReceived(value), live: true)
        let original = try #require(store.mediaSources(for: .attachment(attachment.id), at: Date()).first)
        let before = try store.checkpoint()
        try store.database.write { db in
            try db.execute(sql: """
            CREATE TRIGGER refuseJournal BEFORE INSERT ON serviceJournal
            BEGIN SELECT RAISE(ABORT, 'refused'); END;
            """)
        }
        value.attachments = []
        #expect(throws: (any Error).self) { try store.append(.messageUpdated(value), live: true) }
        #expect(try store.isCurrentMediaSource(original, at: Date()))
        #expect(try store.checkpoint() == before)
    }

    @Test func queryFactsExpireAndCannotOverrideATombstoneOrClearedHistory() throws {
        let store = try store()
        let date = Date(timeIntervalSince1970: 100)
        try store.rememberQueryMedia([message()], at: date)
        let query = try #require(store.mediaSources(for: .attachment(attachment.id), at: date).first)
        #expect(try !store.isCurrentMediaSource(query, at: date.addingTimeInterval(900)))
        _ = try store.append(.messageReceived(message()), live: true)
        _ = try store.append(.messageDeleted(id: messageID, in: conversation), live: true)
        try store.rememberQueryMedia([message()], at: date)
        #expect(try store.mediaSources(for: .attachment(attachment.id), at: date).isEmpty)
        _ = try store.append(
            .conversationRemoved(
                conversationID: conversation,
                historyBefore: Date(timeIntervalSince1970: 20)
            ),
            live: true
        )
        try store.rememberQueryMedia([message(9)], at: date)
        #expect(try store.mediaSources(for: .attachment("media-9"), at: date).isEmpty)
    }

    @Test func memberAndConversationPhotosUseIssuedOriginsAndChangedPhotosRevokeTheirVersions() throws {
        let store = try store()
        var member = Member(id: .init("member"), kind: .human, displayName: "Demo", avatarURL: image)
        _ = try store.append(.membersResolved([member]), live: false)
        let photo = try #require(store.mediaSources(for: .remoteImage(image), at: Date()).first)
        #expect(photo.origin == .member(member.id))
        #expect(try store.isCurrentMediaSource(photo, at: Date()))
        member.avatarURL = cardImage
        _ = try store.append(.membersResolved([member]), live: false)
        #expect(try !store.isCurrentMediaSource(photo, at: Date()))
        let room = Conversation(id: conversation, kind: .space, avatarURL: image)
        _ = try store.append(.conversationUpdated(room), live: false)
        #expect(try store.mediaSources(for: .remoteImage(image), at: Date()).first?
            .origin == .conversation(conversation))
    }

    @Test func unknownSelectorRetainsItsStructuredPayloadAndNeverBecomesAuthority() throws {
        let value = JSONValue.object([
            "type": .string("future"),
            "nested": .object(["source": .string("opaque")])
        ])
        let selector = try ServiceCodec.decode(MediaSelector.self, from: value)
        #expect(try ServiceCodec.value(selector) == value)
        #expect(throws: ServiceFailure.unsupportedOperation) { try store().mediaSources(
            for: selector,
            at: Date()
        ) }
    }

    @Test func queryPreviewsAndPhotosExpireWithoutInsertingCanonicalChatState() throws {
        let store = try store()
        let date = Date(timeIntervalSince1970: 100)
        let room = Conversation(id: .init("unjoined"), kind: .space, avatarURL: image)
        var preview = message()
        preview.conversationID = room.id
        try store.rememberQueryConversations([room], at: date)
        try store.rememberQueryMedia([preview], at: date)
        #expect(try store.conversation(room.id) == nil)
        #expect(try !store.mediaSources(for: .remoteImage(image), at: date).isEmpty)
        #expect(try !store.mediaSources(for: .attachment(attachment.id), at: date).isEmpty)
        #expect(try store.mediaSources(for: .attachment(attachment.id), at: date.addingTimeInterval(900))
            .isEmpty)
        _ = try store.append(
            .conversationsChanged([Conversation(id: conversation, kind: .space)]),
            live: false
        )
        #expect(try store.mediaSources(for: .attachment(attachment.id), at: date).isEmpty)
    }

    @Test func bootstrapSkipsCorruptCachedBodiesAndReopenKeepsStableVersionsAndCounts() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("media.sqlite").path
        // An existing projection predates the derived catalog; no second live writer is opened.
        var first: SQLiteAccountStorage? = try SQLiteAccountStorage(account: .init("account"), path: path)
        _ = try first?.append(
            .conversationsChanged([Conversation(id: conversation, kind: .space)]),
            live: false
        )
        _ = try first?.append(.messageReceived(message()), live: true)
        _ = try first?.append(.messageReceived(message(1)), live: true)
        try first?.database.write { db in
            try db.execute(sql: "DROP TABLE serviceMediaReference")
            try db.execute(sql: "UPDATE message SET attachments = 'invalid' WHERE id = 'message-1'")
        }
        first = nil
        var second: SQLiteAccountStorage? = try SQLiteAccountStorage(account: .init("account"), path: path)
        let source = try #require(second?.mediaSources(for: .attachment(attachment.id), at: Date()).first)
        #expect(try second?.mediaSources(for: .attachment("media-1"), at: Date()).isEmpty == true)
        #expect(try second?.database.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM message")
        } == 2)
        second = nil
        let third = try SQLiteAccountStorage(account: .init("account"), path: path)
        #expect(try third.isCurrentMediaSource(source, at: Date()))
        try third.database.write { db in
            try db.execute(sql: "DELETE FROM message WHERE id = 'message'")
            let actual = try Int.fetchOne(db, sql: "SELECT count(*) FROM serviceMediaReference")
            let counted = try Int.fetchOne(
                db,
                sql: "SELECT entryCount FROM serviceMediaMetadata WHERE id = 1"
            )
            #expect(actual == 0)
            #expect(counted == actual)
        }
    }

    @Test func indexedLookupDoesNotDecodeUnrelatedHistoryAtRealisticSize() throws {
        let store = try store()
        let clock = ContinuousClock()
        let start = clock.now
        for batch in 0 ..< 50 {
            let rows = (batch * 200 ..< (batch + 1) * 200).map { message($0) }
            _ = try store.append(
                .historyLoaded(MessageHistoryUpdate(messages: rows, conversationID: conversation)),
                live: false
            )
        }
        let indexed = clock.now
        let source = try #require(store.mediaSources(for: .attachment("media-9999"), at: Date()).first)
        for _ in 0 ..< 100 {
            #expect(try store.isCurrentMediaSource(source, at: Date()))
        }
        #expect(indexed.duration(to: clock.now) < .seconds(5))
        print(
            "Catalog 10k: \(start.duration(to: indexed)); 100 checks: \(indexed.duration(to: clock.now))"
        )
    }
}
