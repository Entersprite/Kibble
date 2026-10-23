import ChatAPI
import ChatKit
import ChatService
import Foundation
import Testing
@testable import ChatServiceStorage

extension MediaCatalogTests {
    @Test func freshPinTokensResolveAlongsideAnAlreadyStoredOriginal() throws {
        let store = try store()
        let original = message()
        _ = try store.append(.messageReceived(original), live: false)
        var pin = original
        let fresh = Attachment(
            id: "pin-response-token",
            name: attachment.name,
            contentType: attachment.contentType
        )
        pin.attachments = [fresh]
        try store.rememberPinnedMedia([pin], in: conversation, at: Date())
        #expect(try store.mediaSources(for: .attachment(fresh.id), at: Date()).count == 1)
        #expect(try store.mediaSources(for: .attachment(attachment.id), at: Date()).count == 1)
        let context = try MessageHistoryUpdate(messages: [original], conversationID: conversation)
        _ = try store.append(.historyLoaded(context), live: false)
        #expect(try store.mediaSources(for: .attachment(fresh.id), at: Date()).count == 1)
        _ = try store.append(.messageDeleted(id: messageID, in: conversation), live: true)
        #expect(try store.mediaSources(for: .attachment(fresh.id), at: Date()).isEmpty)
        try store.rememberPinnedMedia([pin], in: conversation, at: Date())
        #expect(try store.mediaSources(for: .attachment(fresh.id), at: Date()).isEmpty)
    }

    @Test func pinnedMediaExpiresRenewsAndRetiresWhenTheCollectionChanges() throws {
        let store = try store()
        let date = Date(timeIntervalSince1970: 100)
        try store.rememberPinnedMedia([message()], in: conversation, at: date)
        let source = try #require(store.mediaSources(for: .attachment(attachment.id), at: date).first)
        #expect(source.origin == .pinnedMessage(conversation, messageID))
        #expect(try !store.isCurrentMediaSource(source, at: date.addingTimeInterval(900)))
        try store.rememberPinnedMedia([message()], in: conversation, at: date.addingTimeInterval(899))
        #expect(try store.isCurrentMediaSource(source, at: date.addingTimeInterval(900)))
        #expect(try self.store().mediaSources(for: .attachment(attachment.id), at: date).isEmpty)
        try store.rememberPinnedMedia([], in: conversation, at: date.addingTimeInterval(900))
        #expect(try !store.isCurrentMediaSource(source, at: date.addingTimeInterval(900)))
    }

    @Test func aLaterHistoryTombstoneRevokesAPinOutsideTheOriginalHistoryWindow() throws {
        let store = try store()
        try store.rememberPinnedMedia([message()], in: conversation, at: Date())
        let source = try #require(store.mediaSources(for: .attachment(attachment.id), at: Date()).first)
        var deleted = message(); deleted.isDeleted = true
        _ = try store.append(.historyLoaded(MessageHistoryUpdate(
            messages: [deleted], conversationID: conversation
        )), live: false)
        #expect(try !store.isCurrentMediaSource(source, at: Date()))
        try store.rememberPinnedMedia([message()], in: conversation, at: Date())
        #expect(try store.mediaSources(for: .attachment(attachment.id), at: Date()).isEmpty)
    }
}
