import ChatKit
import Foundation
import Testing
@testable import ChatPersistence
@testable import SyncEngine

/// The explicit mark's post-fetch `guard !Task.isCancelled`, which the final
/// review found could be deleted with the whole suite green. It is the only
/// thing between a mark cancelled by `stop()` during its fetch and
/// `engine.submit`, which does not check cancellation before `backend.send`.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct MarkReadNowCancellationTests {
    private let conversation = Conversation.ID("space:1")
    private let live = Date(timeIntervalSince1970: 2000)

    private func model(on backend: HangingHistoryBackend) throws -> (ChatSessionModel, ChatStore) {
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        return (ChatSessionModel(store: store, engine: engine, me: nil, markReadDebounce: .zero), store)
    }

    /// Nothing stored, so the mark fetches, and the fetch hangs; a live
    /// message then lands through the consumer - modelled by writing it
    /// straight to the store - which is what the mark would find afterwards.
    private func markHungOnItsFetch(
        _ model: ChatSessionModel,
        _ store: ChatStore,
        _ backend: HangingHistoryBackend
    ) async throws -> Task<Void, Never> {
        var requests = backend.heldRequests.makeAsyncIterator()
        model.markRead(conversation, from: .conversationList)
        let mark = try #require(model.markTasks[conversation])
        let request = await requests.next()
        try #require(request == conversation)
        try store.apply([.upsertMessage(Message(
            id: Message.ID("m:live"), conversationID: conversation, threadID: MessageThread.ID("t"),
            sender: Member.ID("people/other"), text: "hi", createdAt: live
        ))])
        return mark
    }

    private func markReads(_ backend: HangingHistoryBackend) async -> [ChatCommand] {
        await backend.commands.filter {
            if case .markRead = $0 {
                true
            } else {
                false
            }
        }
    }

    /// Sign-out while the mark's fetch hangs. The fetch then answers, and
    /// nothing may be published for the account being signed out of.
    @Test func aMarkStoppedDuringItsFetchPublishesNothingWhenTheFetchReturns() async throws {
        let backend = HangingHistoryBackend(canMarkRead: true)
        let (model, store) = try model(on: backend)
        let mark = try await markHungOnItsFetch(model, store, backend)

        await model.stop()
        await backend.releaseHungRequest()
        await mark.value

        #expect(await markReads(backend).isEmpty)
    }

    /// The control: the same sequence with no `stop()` publishes the live
    /// message's position, so the silence above is the guard and not a
    /// harness that cannot send.
    @Test func theSameMarkLeftRunningPublishesOnceTheFetchReturns() async throws {
        let backend = HangingHistoryBackend(canMarkRead: true)
        let (model, store) = try model(on: backend)
        let mark = try await markHungOnItsFetch(model, store, backend)

        await backend.releaseHungRequest()
        await mark.value

        #expect(await markReads(backend) == [.markRead(conversationID: conversation, upTo: live)])
    }
}
