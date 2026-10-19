import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import ChatPersistence
@testable import SyncEngine

struct ConversationActionStoreTests {
    @Test func manualUnreadSurvivesLateReceiptsAndClearsExplicitly() throws {
        let store = try ChatStore.inMemory()
        let id = Conversation.ID("opaque")
        let at = Date(timeIntervalSince1970: 1_790_000_000.123456)
        try store.apply([.upsertConversation(Conversation(id: id, kind: .directMessage, readPosition: at))])
        try store.apply(SyncReducer.reduce(.conversationUnreadMarkChanged(conversationID: id, at: at)).writes)
        try store.apply([.setReadState(conversation: id, lastReadAt: at.addingTimeInterval(1), unread: 0)])
        #expect(try store.conversations().first?.hasUnread == true)
        #expect(try store.conversations().first?.markedUnreadAt == at)
        try store.apply([
            .setConversationUnreadMark(conversation: id, at: nil),
            .setReadState(conversation: id, lastReadAt: at.addingTimeInterval(2), unread: 0)
        ])
        #expect(try store.conversations().first?.hasUnread == false)
    }

    @Test(arguments: [false, true])
    func removingKeepsHistoryUnlessDeletionWasConfirmed(_ deleting: Bool) throws {
        let store = try ChatStore.inMemory()
        let world = FixtureWorld.minimal
        let conversation = try #require(world.conversations.first)
        let messages = world.messages(in: conversation.id)
        try store.apply([.upsertConversation(conversation)] + messages.map(StoreWrite.upsertMessage))
        let event = ChatEvent.conversationRemoved(
            conversationID: conversation.id,
            historyBefore: deleting ? .distantFuture : nil
        )
        try store.apply(SyncReducer.reduce(event).writes)
        #expect(try store.conversations().isEmpty)
        #expect(try store.messages(in: conversation.id).count == (deleting ? 0 : messages.count))
        #expect(SyncReducer.reduce(event).effects == [.withdrawAnnouncements(
            conversation.id,
            upTo: .distantFuture
        )])
    }
}

extension ConversationActionStoreTests {
    @Test func aReturningWorldSnapshotPurgesOnlyHistoryThroughItsCutoff() throws {
        let store = try ChatStore.inMemory()
        var conversation = FixtureWorld.minimal.conversations[0]
        var old = FixtureWorld.minimal.messages(in: conversation.id)[0]
        old.createdAt = Date(timeIntervalSince1970: 1000)
        var newer = old
        newer.id = Message.ID("newer")
        newer.createdAt = Date(timeIntervalSince1970: 2000)
        try store.apply([.upsertConversation(conversation), .upsertMessage(old), .upsertMessage(newer)])
        conversation.historyClearedBefore = Date(timeIntervalSince1970: 1500)
        try store.apply([.replaceConversations([conversation])])
        #expect(try store.messages(in: conversation.id).map(\.id) == [newer.id])
        conversation.historyClearedBefore = nil
        try store.apply([.replaceConversations([conversation])])
        #expect(try store.conversations().first?.historyClearedBefore == Date(timeIntervalSince1970: 1500))
    }

    @Test func aLateDirectoryAnswerDoesNotRestoreRemovedMembership() throws {
        let store = try ChatStore.inMemory()
        let conversation = FixtureWorld.minimal.conversations[0]
        try store.apply([
            .upsertConversation(conversation),
            .removeConversation(conversation: conversation.id, historyBefore: nil)
        ])
        try store.apply(SyncReducer.reduce(.membersChanged(
            conversationID: conversation.id,
            members: FixtureWorld.minimal.members
        )).writes)
        #expect(try store.conversations().isEmpty)
        #expect(try !store.members().isEmpty)
    }
}

extension ConversationActionStoreTests {
    @Test func deletionCutoffSurvivesRemovalAndRejectsLateHistoryPages() throws {
        let store = try ChatStore.inMemory()
        let conversation = FixtureWorld.minimal.conversations[0]
        var old = FixtureWorld.minimal.messages(in: conversation.id)[0]
        old.createdAt = Date(timeIntervalSince1970: 1000)
        try store.apply([.upsertConversation(conversation), .upsertMessage(old)])
        try store.apply([.removeConversation(
            conversation: conversation.id,
            historyBefore: Date(timeIntervalSince1970: 1500)
        )])
        try store.apply([.upsertMessage(old), .insertMessageIfAbsent(old)])
        #expect(try store.messages(in: conversation.id).isEmpty)
        try store.apply([.restoreConversation(conversation)])
        #expect(try store.conversations().first?.historyClearedBefore == Date(timeIntervalSince1970: 1500))
        try store.apply([.upsertMessage(old)])
        #expect(try store.messages(in: conversation.id).isEmpty)
        try store.erase()
        try store.apply([.upsertConversation(conversation), .upsertMessage(old)])
        #expect(try store.messages(in: conversation.id).count == 1)
    }
}
