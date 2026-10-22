import ChatAPI
import ChatKit
import ChatServiceStorage
import Foundation
import Testing
@testable import ChatService

/// A reaction fences in-flight history of the conversation that holds its
/// message, and all in-flight history only when the store does not know it.
@Suite(.timeLimit(.minutes(1)))
struct ReactionFenceTests {
    enum Target: CaseIterable {
        case anotherConversation, thisConversation, unknownMessage
    }

    let shared = ReconciliationBackend.conversation
    let elsewhere = Conversation.ID("elsewhere")
    var stored: Message {
        Message(
            id: .init("elsewhere-message"), conversationID: elsewhere, threadID: .init("elsewhere-thread"),
            sender: .init("peer"), text: "Elsewhere", createdAt: ReconciliationBackend.date
        )
    }

    @Test func theStoreNamesAStoredMessagesConversationWhateverItsConfidence() throws {
        let store: any ServiceAccountStorage = try SQLiteAccountStorage(
            account: .init("account"),
            path: ":memory:"
        )
        _ = try store.append(.conversationsChanged([Conversation(id: elsewhere, kind: .space)]), live: false)
        _ = try store.append(.messageReceived(stored), live: true)
        #expect(try store.conversationID(containing: stored.id) == elsewhere)
        #expect(try store.conversationID(containing: .init("not-stored")) == nil)
        _ = try store.append(.conversationHistoryInvalidated([elsewhere]), live: false)
        // Control: the row is no longer confirmed history.
        #expect(try store.recentHistory(in: elsewhere, limit: 10).isEmpty)
        #expect(try store.conversationID(containing: stored.id) == elsewhere)
    }

    @Test(arguments: Target.allCases)
    func aReactionRestartsOnlyReadsItCouldMakeStale(_ target: Target) async throws {
        let harness = try await ReconciliationHarness.make()
        let runtime = try await prepared(harness)
        let before = await harness.backend.historyReads
        await harness.backend.holdHistoryQueries()
        let shared = shared
        let query = Task { try await harness.call(LoadMessages(conversationID: shared)) }
        do {
            try await authEventually { await harness.backend.historyReads == before + 1 }
            let world = await runtime.historyWorldVersion
            let fenced = target == .anotherConversation ? elsewhere : shared
            let version = await runtime.historyVersions[fenced]
            let message: Message.ID = switch target {
            case .anotherConversation: stored.id
            case .thisConversation: ReconciliationBackend.message.id
            case .unknownMessage: .init("not-stored")
            }
            await harness.backend.emit(.reactionChanged(
                messageID: message, reactions: [Reaction(emoji: "+1", count: 1)]
            ))
            // The positive control: the fence this reaction should move did move.
            try await authEventually {
                target == .unknownMessage
                    ? await runtime.historyWorldVersion != world
                    : await runtime.historyVersions[fenced] != version
            }
            let restarts = target != .anotherConversation
            #expect(await runtime.historyWorldVersion == world || target == .unknownMessage)
            await harness.backend.releaseHistoryQuery(before + 1)
            if restarts {
                try await authEventually { await harness.backend.historyReads == before + 2 }
            }
            await harness.backend.releaseAllHistoryQueries()
            _ = try await query.value
            #expect(await harness.backend.historyReads == before + (restarts ? 2 : 1))
            await harness.service.shutdown()
        } catch {
            await harness.backend.releaseAllHistoryQueries()
            _ = await query.result
            await harness.service.shutdown()
            throw error
        }
    }

    /// Both conversations exist, and each holds a stored message.
    private func prepared(_ harness: ReconciliationHarness) async throws -> AccountRuntime {
        try await authEventually {
            guard let runtime = await harness.service.runtimes[harness.record.id] else { return false }
            let world = await runtime.worldRefresh
            return try world == nil && harness.storage.conversation(shared) != nil
        }
        try await harness.addConversation(elsewhere)
        await harness.backend.emit(.messageReceived(stored))
        try await authEventually { try harness.storage.conversationID(containing: stored.id) == elsewhere }
        _ = try await harness.call(LoadMessages(conversationID: shared))
        try await authEventually {
            try harness.storage.conversationID(containing: ReconciliationBackend.message.id) == shared
        }
        return try #require(await harness.service.runtimes[harness.record.id])
    }
}
