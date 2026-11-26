import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import ChatPersistence
@testable import SyncEngine

/// An optimistic copy and the server's echo are the same message, and the store
/// has to end up holding one row rather than two.
struct OptimisticSendTests {
    private func store() throws -> ChatStore {
        try ChatStore.inMemory()
    }

    private func message(
        id: String,
        localID: String?,
        text: String = "hello"
    ) -> Message {
        Message(
            id: Message.ID(id),
            conversationID: Conversation.ID("space/s-1"),
            threadID: MessageThread.ID("t-1"),
            sender: Member.ID("u-1"),
            text: text,
            createdAt: Date(timeIntervalSince1970: 1000),
            localID: localID
        )
    }

    /// The echo carries a real server id and the same `localID`. Upserting it
    /// must replace the optimistic row rather than sit beside it, because the
    /// two ids differ and an id-keyed upsert alone would leave both.
    @Test func theEchoReplacesTheOptimisticCopy() throws {
        let store = try store()
        try store.apply([.upsertMessage(message(id: "local/l-1", localID: "l-1"))])
        try store.apply([.upsertMessage(message(id: "m-real", localID: "l-1"))])

        let messages = try store.messages(in: Conversation.ID("space/s-1"))
        #expect(messages.count == 1)
        #expect(messages.first?.id.rawValue == "m-real")
    }

    /// Somebody else's message carries no `localID`, and two of those must not
    /// collapse into one just because they both have none.
    @Test func messagesWithNoLocalIDAreNeverMerged() throws {
        let store = try store()
        try store.apply([.upsertMessage(message(id: "m-1", localID: nil))])
        try store.apply([.upsertMessage(message(id: "m-2", localID: nil))])

        let messages = try store.messages(in: Conversation.ID("space/s-1"))
        #expect(messages.count == 2)
    }

    /// Re-delivery of the same server message lands the latest content in one
    /// row.
    ///
    /// This does **not** discriminate the delete-then-upsert write path from a
    /// plain in-place `upsert`: `MessageRow` covers every column the `message`
    /// table has, and no other table is keyed on `message.id`, so for a
    /// re-delivery under an unchanged id the two are byte-identical through
    /// `ChatStore`'s public surface as it stands today - verified by running
    /// this test with the delete's `AND id <> ?` clause removed (passed), and
    /// again with the entire delete-before-upsert block removed (passed).
    /// `theEchoReplacesTheOptimisticCopy` above is what actually exercises the
    /// delete: there the incoming id differs from the row it must replace,
    /// which is the one case a plain upsert cannot handle on its own.
    @Test func redeliveringTheSameServerMessageStillLandsTheLatestContent() throws {
        let store = try store()
        try store.apply([.upsertMessage(message(id: "m-1", localID: "l-1"))])
        try store.apply([.upsertMessage(message(id: "m-1", localID: "l-1", text: "edited"))])

        let messages = try store.messages(in: Conversation.ID("space/s-1"))
        #expect(messages.count == 1)
        #expect(messages.first?.text == "edited")
    }

    /// A retracted message must not cost the user what they typed. The
    /// retraction itself is old behaviour (`record(_:undoing:)` removing the
    /// optimistic row); handing the text back is not.
    @MainActor
    @Test func aFailedSendReturnsTheText() async throws {
        let backend = RecordingBackend()
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let model = ChatSessionModel(store: store, engine: engine, me: nil, markReadDebounce: .zero)
        try await model.start()
        await settleAutoMarkRead()
        model.select(FixtureWorld.minimal.messages[0].conversationID)
        await settleAutoMarkRead()

        await backend.failSubmissions(true)
        model.send(ComposedMessage(text: "the message that did not make it"))
        await settleAutoMarkRead()

        #expect(model.failedDraft?.text == "the message that did not make it")
        await model.stop()
    }

    /// **The mistake this guards.** A failure surfacing after the user has
    /// moved on would restore their text into somebody else's composer - the
    /// same class of error `ChatWindow`'s `.id(conversation.id)` already
    /// exists to prevent. The draft is offered only while its own
    /// conversation is selected.
    @MainActor
    @Test func aFailedSendIsNotOfferedInAnotherConversation() async throws {
        let backend = RecordingBackend()
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let model = ChatSessionModel(store: store, engine: engine, me: nil, markReadDebounce: .zero)
        try await model.start()
        await settleAutoMarkRead()
        let first = FixtureWorld.minimal.messages[0].conversationID
        model.select(first)
        await settleAutoMarkRead()

        await backend.failSubmissions(true)
        model.send(ComposedMessage(text: "meant for the first conversation"))
        await settleAutoMarkRead()
        #expect(model.failedDraft != nil)

        let other = try #require(model.conversations.first { $0.id != first })
        model.select(other.id)
        await settleAutoMarkRead()

        #expect(model.failedDraft == nil)

        // And it is still there when the user comes back, because it was
        // withheld rather than discarded.
        model.select(first)
        await settleAutoMarkRead()
        #expect(model.failedDraft?.text == "meant for the first conversation")
        await model.stop()
    }

    @MainActor
    @Test func refusedSendsInOneConversationCanBothBeRestored() async throws {
        let backend = RecordingBackend()
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let model = ChatSessionModel(store: store, engine: engine, me: nil, markReadDebounce: .zero)
        try await model.start()
        let conversation = FixtureWorld.minimal.messages[0].conversationID
        let first = ComposedMessage(text: "First refused message")
        let second = ComposedMessage(text: "Second refused message")
        await backend.failSubmissions(true)
        model.select(conversation)

        model.send(first)
        await settleAutoMarkRead(until: "the first send finishes") { model.sendTasks.isEmpty }
        model.send(second)
        await settleAutoMarkRead(until: "the second send finishes") { model.sendTasks.isEmpty }

        #expect(model.failedDraft == first)
        let firstOffer = try #require(model.failedDraftOffer)
        model.clearFailedDraft(in: conversation, matching: firstOffer.id)
        model.clearFailedDraft(in: conversation, matching: firstOffer.id)
        #expect(model.failedDraft == second)
        model.clearFailedDraft()
        #expect(model.failedDraft == nil)
        await model.stop()
    }

    @MainActor
    @Test func refusedSendsInDifferentConversationsKeepBothDrafts() async throws {
        let backend = RecordingBackend()
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let model = ChatSessionModel(store: store, engine: engine, me: nil, markReadDebounce: .zero)
        try await model.start()
        let first = FixtureWorld.minimal.messages[0].conversationID
        await settleAutoMarkRead(until: "the other conversation appears") {
            model.conversations.contains { $0.id != first }
        }
        let other = try #require(model.conversations.first { $0.id != first })
        let firstDraft = ComposedMessage(text: "Draft in the first conversation")
        let secondDraft = ComposedMessage(text: "Draft in the second conversation")
        await backend.failSubmissions(true)

        model.select(first)
        model.send(firstDraft)
        await settleAutoMarkRead(until: "the first refused draft comes back") {
            model.failedDraft == firstDraft
        }

        model.select(other.id)
        model.send(secondDraft)
        await settleAutoMarkRead(until: "the second refused draft comes back") {
            model.failedDraft == secondDraft
        }

        model.select(first)
        #expect(model.failedDraft == firstDraft)
        let firstOffer = try #require(model.failedDraftOffer)

        model.select(other.id)
        model.clearFailedDraft(in: firstOffer.conversationID, matching: firstOffer.id)
        #expect(model.failedDraft == secondDraft)

        model.select(first)
        #expect(model.failedDraft == nil)
        await model.stop()
    }

    /// Consumed once. A draft that came back and was adopted must not come
    /// back again on the next redraw.
    @MainActor
    @Test func aRestoredDraftIsNotOfferedTwice() async throws {
        let backend = RecordingBackend()
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let model = ChatSessionModel(store: store, engine: engine, me: nil, markReadDebounce: .zero)
        try await model.start()
        await settleAutoMarkRead()
        model.select(FixtureWorld.minimal.messages[0].conversationID)
        await settleAutoMarkRead()

        await backend.failSubmissions(true)
        model.send(ComposedMessage(text: "adopted once"))
        await settleAutoMarkRead()
        #expect(model.failedDraft != nil)

        model.clearFailedDraft()

        #expect(model.failedDraft == nil)
        await model.stop()
    }
}
