import ChatKit
import ChatRules
import Testing

struct HistoryReducerTests {
    @Test func fetchedHistoryNeverMarksUnreadOrAnnouncesArrivals() throws {
        let message = EventSamples.message
        let update = try MessageHistoryUpdate(messages: [message], conversationID: message.conversationID)
        let reduced = SyncReducer.reduce(.historyLoaded(update))
        #expect(reduced.writes == [.upsertMessage(message)])
        #expect(reduced.effects.isEmpty)
        let followed = try MessageHistoryUpdate(
            messages: [message],
            conversationID: nil,
            keepsReactions: true
        )
        #expect(SyncReducer.reduce(.historyLoaded(followed))
            .writes == [.upsertMessageKeepingReactions(message)])
    }

    @Test func onlyACompleteExplicitThreadListingRemovesAbsentRows() throws {
        let message = EventSamples.message
        let update = try MessageHistoryUpdate(
            messages: [message], conversationID: message.conversationID, threadID: message.threadID,
            isComplete: true
        )
        #expect(SyncReducer.reduce(.historyLoaded(update)).writes == [
            .upsertMessage(message),
            .reconcileThread(
                thread: message.threadID,
                conversation: message.conversationID,
                keeping: [message.id]
            )
        ])
        #expect(SyncReducer.reduce(.mentionBackfillChanged(.init(running: true))).effects.isEmpty)
    }

    /// The account-wide and the per-conversation forms write different things,
    /// and neither has an effect: the service owns refetching.
    @Test func historyConfidenceIsWithdrawnAtTheScopeTheEventNames() {
        let chats = [Conversation.ID("space/a")]
        #expect(SyncReducer.reduce(.historyInvalidated).writes == [.invalidateReplicaHistory])
        let scoped = SyncReducer.reduce(.conversationHistoryInvalidated(chats))
        #expect(scoped.writes == [.invalidateConversationHistory(chats)])
        #expect(scoped.effects.isEmpty)
    }
}
