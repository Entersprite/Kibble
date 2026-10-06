import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import SyncEngine

/// The person's own edit and delete: written at once, sent addressed, undone
/// on refusal - unless the server's version arrived first (edit spec §4).
@MainActor
struct EditDeleteTests {
    private struct Harness {
        let backend: RecordingBackend
        let store: ChatStore
        let model: ChatSessionModel
        let message: Message
    }

    /// `ReactTests.running()`'s harness. `messages[1]` is the person's own.
    private func running(capabilities: Capabilities = .fixture) async throws -> Harness {
        let backend = RecordingBackend(capabilities: capabilities)
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let model = ChatSessionModel(store: store, engine: engine, me: nil, markReadDebounce: .zero)
        try await model.start()
        await settleAutoMarkRead()
        let message = FixtureWorld.minimal.messages[1]
        model.select(message.conversationID)
        await settleAutoMarkRead()
        try #require(model.messages.contains { $0.id == message.id })
        return Harness(backend: backend, store: store, model: model, message: message)
    }

    private func stored(_ harness: Harness) throws -> Message {
        try #require(try harness.store.message(harness.message.id))
    }

    @Test func anEditIsWrittenAtOnceAndSentAddressed() async throws {
        let harness = try await running()
        let mention = Mention(target: .all, start: 0, length: 4)
        harness.model.edit(harness.message.id, to: ComposedMessage(text: "@all fixed", mentions: [mention]))
        // Asserted before any settle: the fixture's own push would correct a
        // bad local write (CLAUDE.md, "a test of quick").
        let local = try stored(harness)
        #expect(local.text == "@all fixed")
        #expect(local.mentions == [mention])
        #expect(local.editedAt != nil)
        await settleAutoMarkRead()
        #expect(await harness.backend.commands.last == .editMessage(
            id: harness.message.id, text: "@all fixed",
            conversationID: harness.message.conversationID, threadID: harness.message.threadID,
            mentions: [mention]
        ))
        await harness.model.stop()
    }

    /// Guard: unchanged text and mentions send nothing.
    @Test func anUnchangedEditSendsNothing() async throws {
        let harness = try await running()
        let before = await harness.backend.commands.count
        harness.model.edit(
            harness.message.id,
            to: ComposedMessage(text: harness.message.text, mentions: harness.message.mentions)
        )
        await settleAutoMarkRead()
        #expect(await harness.backend.commands.count == before)
        #expect(try stored(harness).editedAt == harness.message.editedAt)
        await harness.model.stop()
    }

    @Test func aRefusedEditPutsTheOldTextBack() async throws {
        let harness = try await running()
        await harness.backend.failSubmissions(true)
        harness.model.edit(harness.message.id, to: ComposedMessage(text: "fixed"))
        await settleAutoMarkRead()
        let restored = try stored(harness)
        #expect(restored.text == harness.message.text)
        #expect(restored.editedAt == harness.message.editedAt)
        #expect(harness.model.lastError != nil)
        await harness.model.stop()
    }

    /// Review Focus 1. The push lands after the local write and before the
    /// refusal is processed: the server's version must stand.
    @Test func aRefusalAfterAPushKeepsThePush() async throws {
        let harness = try await running()
        await harness.backend.failSubmissions(true)
        harness.model.edit(harness.message.id, to: ComposedMessage(text: "mine"))
        var server = harness.message
        server.text = "from another device"
        server.editedAt = Date(timeIntervalSince1970: 2_000_000_000)
        try harness.store.apply([.upsertMessageKeepingReactions(server)])
        await settleAutoMarkRead()
        #expect(try stored(harness).text == "from another device")
        await harness.model.stop()
    }

    @Test func aDeleteIsATombstoneAtOnceAndSentAddressed() async throws {
        let harness = try await running()
        harness.model.delete(harness.message.id)
        #expect(try stored(harness).isDeleted)
        await settleAutoMarkRead()
        #expect(await harness.backend.commands.last == .deleteMessage(
            id: harness.message.id, conversationID: harness.message.conversationID,
            threadID: harness.message.threadID
        ))
        await harness.model.stop()
    }

    @Test func aRefusedDeletePutsTheMessageBack() async throws {
        let harness = try await running()
        let before = try stored(harness)
        await harness.backend.failSubmissions(true)
        harness.model.delete(harness.message.id)
        await settleAutoMarkRead()
        let restored = try stored(harness)
        #expect(!restored.isDeleted)
        #expect(restored.text == before.text)
        #expect(restored.reactions == before.reactions)
        await harness.model.stop()
    }

    /// Review finding 7: the delete's undo is guarded like the edit's. A row
    /// the server replaced before the refusal arrived stands.
    @Test func aRefusedDeleteAfterAPushKeepsThePush() async throws {
        let harness = try await running()
        await harness.backend.failSubmissions(true)
        harness.model.delete(harness.message.id)
        var server = harness.message
        server.text = "from another device"
        try harness.store.apply([.upsertMessageKeepingReactions(server)])
        await settleAutoMarkRead()
        #expect(try stored(harness).text == "from another device")
        await harness.model.stop()
    }

    /// Guard: a message still sending has no server id to address.
    @Test func aMessageStillSendingIsNeitherEditedNorDeleted() async throws {
        let harness = try await running()
        var pending = harness.message
        pending.id = Message.ID("local/abc")
        try harness.store.apply([.upsertMessage(pending)])
        let before = await harness.backend.commands.count
        harness.model.edit(pending.id, to: ComposedMessage(text: "x"))
        harness.model.delete(pending.id)
        await settleAutoMarkRead()
        #expect(await harness.backend.commands.count == before)
        #expect(try harness.store.message(pending.id)?.text == pending.text)
        await harness.model.stop()
    }

    /// Guard: a backend that cannot edit or delete is never asked to.
    @Test func withoutTheCapabilityNothingIsWritten() async throws {
        let harness = try await running(capabilities: Capabilities(canSendMessages: true))
        harness.model.edit(harness.message.id, to: ComposedMessage(text: "x"))
        harness.model.delete(harness.message.id)
        let row = try stored(harness)
        #expect(row.text == harness.message.text)
        #expect(!row.isDeleted)
        await harness.model.stop()
    }
}
