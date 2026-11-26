import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import ChatPersistence
@testable import SyncEngine

struct ConversationActivityTests {
    @Test(arguments: [false, true])
    func newMessagesBumpActivityAndStaleSnapshotsCannotMoveItBack(reply: Bool) throws {
        let store = try ChatStore.inMemory()
        var conversation = FixtureWorld.minimal.conversations[0]
        conversation.lastActivity = Date(timeIntervalSince1970: 10)
        var message = FixtureWorld.minimal.messages(in: conversation.id)[0]
        message.isReply = reply
        message.createdAt = Date(timeIntervalSince1970: 20)
        try store.apply([.upsertConversation(conversation), .upsertMessageKeepingReactions(message)])
        #expect(try store.conversations().first?.lastActivity == message.createdAt)
        try store.apply([.upsertConversation(conversation)])
        #expect(try store.conversations().first?.lastActivity == message.createdAt)
    }

    @Test func historyLoadingDoesNotInventNewActivity() throws {
        let store = try ChatStore.inMemory()
        var conversation = FixtureWorld.minimal.conversations[0]
        conversation.lastActivity = Date(timeIntervalSince1970: 10)
        var message = FixtureWorld.minimal.messages(in: conversation.id)[0]
        message.createdAt = Date(timeIntervalSince1970: 20)
        try store.apply([.upsertConversation(conversation), .upsertMessage(message)])
        #expect(try store.conversations().first?.lastActivity == conversation.lastActivity)
        message.isDeleted = true
        try store.apply([.upsertMessageKeepingReactions(message)])
        #expect(try store.conversations().first?.lastActivity == conversation.lastActivity)
    }
}
