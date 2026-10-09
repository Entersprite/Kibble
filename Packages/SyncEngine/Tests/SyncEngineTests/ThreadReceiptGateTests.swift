import ChatKit
import Foundation
import Testing
@testable import SyncEngine

/// A thread's read goes through the read-receipt gate like a conversation's
/// (threads spec §4.3), and so does the clear sent before it. A manual Mark
/// as Unread does not, because it tells no one anything.
struct ThreadReceiptGateTests {
    private let quiet = Conversation(id: Conversation.ID("dm/quiet"), kind: .directMessage)
    private let open = Conversation(id: Conversation.ID("dm/open"), kind: .directMessage)
    private let thread = MessageThread.ID("thread:gate")
    private let at = Date(timeIntervalSince1970: 1_790_000_000)

    /// `acceptWithoutForwarding`, so a refusal can only be the gate's.
    private func harness() async throws -> (SyncEngine, RecordingBackend) {
        let backend = RecordingBackend()
        await backend.acceptWithoutForwarding(true)
        let store = try ChatStore.inMemory()
        try store.apply([.replaceConversations([quiet, open])])
        return (SyncEngine(backend: backend, store: store), backend)
    }

    private func read(in conversation: Conversation) -> ChatCommand {
        .markThreadRead(conversationID: conversation.id, threadID: thread, upTo: at)
    }

    private func unreadMark(in conversation: Conversation, at position: Date?) -> ChatCommand {
        .setThreadUnreadMark(conversationID: conversation.id, threadID: thread, at: position)
    }

    @Test func withholdingRefusesAThreadReadAndItsClearButNotAMarkAsUnread() async throws {
        let (engine, backend) = try await harness()
        engine.readReceipts.set(.withhold)
        #expect(await !(engine.submit(read(in: open))))
        #expect(await !(engine.submit(unreadMark(in: open, at: nil))))
        #expect(await engine.submit(unreadMark(in: open, at: at)))
        #expect(await backend.commands == [unreadMark(in: open, at: at)])
    }

    @Test func aConversationWithReceiptsOffRefusesItsThreadReadsAndNotItsNeighbors() async throws {
        let (engine, backend) = try await harness()
        var settings = NotificationSettings()
        settings.setRule(NotificationRule(readReceipts: false), for: .conversation(quiet.id), at: at, by: "t")
        engine.readReceipts.set(.resolve(settings))
        #expect(await !(engine.submit(read(in: quiet))))
        #expect(await engine.submit(read(in: open)))
        #expect(await backend.commands == [read(in: open)])
    }

    @Test func ghostModeWithholdsAThreadReadAndNotAMarkAsUnread() async throws {
        let (engine, backend) = try await harness()
        await engine.setGhostMode(true)
        #expect(await !(engine.submit(read(in: open))))
        #expect(await engine.submit(unreadMark(in: open, at: at)))
        #expect(await backend.commands == [unreadMark(in: open, at: at)])
    }
}
