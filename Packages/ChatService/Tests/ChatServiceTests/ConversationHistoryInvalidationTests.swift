import ChatAPI
import ChatKit
import Foundation
import Testing
@testable import ChatService
@testable import ChatServiceStorage

/// Withdrawing history confidence from listed conversations leaves every
/// other conversation's saved history, media authority and in-flight reads
/// alone, and refetches a listed one a client is viewing.
@Suite(.timeLimit(.minutes(1)))
struct ConversationHistoryInvalidationTests {
    let first = Conversation.ID("first")
    let second = Conversation.ID("second")

    func message(in conversation: Conversation.ID) -> Message {
        Message(
            id: .init("message-\(conversation.rawValue)"), conversationID: conversation,
            threadID: .init("thread"), sender: .init("sender"), text: "Message",
            createdAt: Date(timeIntervalSince1970: 10),
            attachments: [Attachment(
                id: "media-\(conversation.rawValue)", name: "file", contentType: "text/plain"
            )]
        )
    }

    @Test func onlyTheListedConversationLosesHistoryAndMediaAuthority() throws {
        let store = try SQLiteAccountStorage(account: .init("account"), path: ":memory:")
        _ = try store.append(.conversationsChanged([
            Conversation(id: first, kind: .space), Conversation(id: second, kind: .space)
        ]), live: false)
        _ = try store.append(.messageReceived(message(in: first)), live: true)
        _ = try store.append(.messageReceived(message(in: second)), live: true)
        let date = Date(timeIntervalSince1970: 100)
        #expect(try !store.mediaSources(for: .attachment("media-first"), at: date).isEmpty)

        _ = try store.append(.conversationHistoryInvalidated([first]), live: false)

        #expect(try store.recentHistory(in: first, limit: 10).isEmpty)
        #expect(try store.recentHistory(in: second, limit: 10).map(\.id) == [message(in: second).id])
        #expect(try store.mediaSources(for: .attachment("media-first"), at: date).isEmpty)
        #expect(try !store.mediaSources(for: .attachment("media-second"), at: date).isEmpty)
    }

    /// The account-wide form still withdraws everything: the control.
    @Test func theAccountWideFormStillWithdrawsEveryConversation() throws {
        let store = try SQLiteAccountStorage(account: .init("account"), path: ":memory:")
        _ = try store.append(.conversationsChanged([
            Conversation(id: first, kind: .space), Conversation(id: second, kind: .space)
        ]), live: false)
        _ = try store.append(.messageReceived(message(in: second)), live: true)
        _ = try store.append(.historyInvalidated, live: false)
        #expect(try store.recentHistory(in: second, limit: 10).isEmpty)
    }

    @Test(arguments: [false, true])
    func anotherConversationsInvalidationDoesNotRestartThisRead(sameConversation: Bool) async throws {
        let harness = try await ReconciliationHarness.make()
        try await idle(harness)
        await harness.backend.holdHistoryQueries()
        let shared = ReconciliationBackend.conversation
        let query = Task { try await harness.call(LoadMessages(conversationID: shared)) }
        do {
            try await authEventually { await harness.backend.historyReads == 1 }
            let listed = sameConversation ? shared : Conversation.ID("elsewhere")
            let runtime = try #require(await harness.service.runtimes[harness.record.id])
            let fence = await runtime.historyVersions[listed]
            await harness.backend.emit(.conversationHistoryInvalidated([listed]))
            try await authEventually { await runtime.historyVersions[listed] != fence }
            await harness.backend.releaseHistoryQuery(1)
            if sameConversation {
                // Fenced: the answer predates the withdrawal and is asked again.
                try await authEventually { await harness.backend.historyReads >= 2 }
            }
            await harness.backend.releaseAllHistoryQueries()
            _ = try await query.value
            #expect(await harness.backend.historyReads == (sameConversation ? 2 : 1))
            await harness.service.shutdown()
        } catch {
            await harness.backend.releaseAllHistoryQueries()
            _ = await query.result
            await harness.service.shutdown()
            throw error
        }
    }

    @Test func aViewedConversationIsFetchedAgainAtOnce() async throws {
        let harness = try await ReconciliationHarness.make()
        try await idle(harness)
        let shared = ReconciliationBackend.conversation
        try await harness.hint(.watchConversationActivity(conversationID: shared))
        let runtime = try #require(await harness.service.runtimes[harness.record.id])
        try await authEventually { await runtime.aggregateClientInterests().conversations.contains(shared) }
        let before = await harness.backend.historyReads
        await harness.backend.emit(.conversationHistoryInvalidated([shared]))
        try await authEventually { await harness.backend.historyReads > before }
        try await authEventually { try !harness.history().isEmpty }
        await harness.service.shutdown()
    }

    private func idle(_ harness: ReconciliationHarness) async throws {
        try await authEventually {
            guard let runtime = await harness.service.runtimes[harness.record.id] else { return false }
            let world = await runtime.worldRefresh
            let backfill = await runtime.backfill
            return try world == nil && backfill == nil &&
                harness.storage.conversation(ReconciliationBackend.conversation) != nil
        }
    }
}
