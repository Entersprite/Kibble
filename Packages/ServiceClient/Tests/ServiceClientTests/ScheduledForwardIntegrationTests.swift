import ChatAPI
import ChatKit
import Foundation
import SyncEngine
import Testing

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ScheduledForwardIntegrationTests {
    @Test func aForwardQueuesWithoutPostingOrClearingAnotherComposer() async throws {
        let harness = try await ClientHarness.make(seedSyncedDrafts: true)
        let first = harness.backend(harness.first), second = harness.backend(harness.second)
        let store = try ChatStore.inMemory()
        let model = ChatSessionModel(store: store, engine: SyncEngine(backend: first, store: store))
        try await model.start()
        try await second.connect()
        let room = Conversation.ID("same")
        try await waitFor { model.conversations.contains(where: { $0.id == room }) }
        model.select(room)
        try await harness.providers.incoming(harness.first.id, count: 1)
        try await waitFor { try store.messages(in: room).count == 1 }
        let original = try #require(try store.messages(in: room).first)
        let time = Date(timeIntervalSince1970: 2_000_000_000)
        let address = ComposerDraftAddress(conversation: room)
        let draft = try await first.syncedDrafts(at: address, after: nil).drafts
        try await rejectUnknownSource(first, original: original, destination: room, time: time)

        #expect(await model.scheduleForward(original.id, to: room, comment: "Comment", at: time))
        #expect(model.schedules.receipts.isEmpty)
        #expect(try await first.syncedDrafts(at: address, after: nil).drafts == draft)
        #expect(try await first.loadMessages(in: room, before: nil).map(\.id) == [original.id])
        #expect(try await second.scheduledMessages(after: nil).messages.isEmpty)
        let queued = try #require(try await first.scheduledMessages(after: nil).messages.first)
        #expect(queued.isForward == true && queued.body.content?.forwardSource == nil)
        let edited = try await first.editScheduledMessage(queued.id, body: ComposedMessage(text: ""))
        #expect(edited.isForward == true && edited.body.text.isEmpty)
        try await first.sendScheduledMessageNow(queued.id)
        let delivered = try await first.loadMessages(in: room, before: nil)
        #expect(delivered.count == 2)
        #expect(delivered.contains { $0.content?.forwarded?.source.id == original.id && $0.text.isEmpty })
        #expect(try await first.scheduledMessages(after: nil).messages.isEmpty)
        await model.stop()
        await second.disconnect()
        await harness.service.shutdown()
    }

    private func rejectUnknownSource(
        _ backend: any ChatBackend, original: Message, destination: Conversation.ID, time: Date
    ) async throws {
        var foreign = original
        foreign.conversationID = Conversation.ID("other-account")
        let body = ComposedMessage(
            text: "",
            content: MessageContent(forwardSource: MessageQuote(message: foreign))
        )
        await #expect(throws: ServiceFailure.notAuthorized) {
            try await backend.scheduleMessage(in: destination, thread: nil, body: body, at: time)
        }
    }

    private func waitFor(_ condition: @MainActor () throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while try !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(try condition())
    }
}
