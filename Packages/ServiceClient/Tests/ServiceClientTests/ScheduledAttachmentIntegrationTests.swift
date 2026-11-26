import ChatAPI
import ChatKit
import Foundation
import SyncEngine
import Testing

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ScheduledAttachmentIntegrationTests {
    @Test func schedulesAnAttachmentBatchWithTheBoundDraftBeforeSendingAnything() async throws {
        let harness = try await ClientHarness.make(uploads: true, seedSyncedDrafts: true)
        let backend = harness.backend(harness.first)
        let store = try ChatStore.inMemory()
        let model = ChatSessionModel(store: store, engine: SyncEngine(backend: backend, store: store))
        try await model.start()
        try await waitFor { model.me == harness.first.selfID && !model.conversations.isEmpty }
        let room = ComposerDraftAddress(conversation: .init("same"))
        let draft = try #require(await backend.syncedDrafts(at: room, after: nil).drafts.first)
        let caption = ComposedMessage(text: "Scheduled caption")
        let date = Date(timeIntervalSince1970: 2_000_000_000)
        let forged = Attachment(id: "unissued", name: "fake.txt", contentType: "text/plain")
        await #expect(throws: ServiceFailure.notAuthorized) {
            try await backend.scheduleWithAttachments(
                in: room, body: caption, attachments: [forged], at: date, converting: draft
            )
        }
        #expect(try await backend.syncedDrafts(at: room, after: nil).drafts == [draft])

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bytes = Data("scheduled attachment fixture".utf8)
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        model.select(room.conversation)
        model.stage(["one.txt", "two.txt"].map { file($0, at: url, size: bytes.count) }, in: .conversation)
        let destination = MessageAddress(conversation: room.conversation)
        let began = model.scheduleMessage(
            caption,
            draft: caption,
            at: date,
            to: destination,
            prepareDraft: { draft },
            confirmed: {}
        )
        #expect(began)
        try await waitFor { model.schedules.receipts[destination] != nil }
        #expect(model.stagedAttachments.isEmpty)
        let item = try #require(await backend.scheduledMessages(after: nil).messages.first)
        #expect(item.id.queueID == draft.id.record && item.attachmentNames == ["one.txt", "two.txt"])
        #expect(try await backend.syncedDrafts(at: room, after: nil).drafts.isEmpty)
        #expect(try await backend.loadMessages(in: room.conversation, before: nil).isEmpty)

        try await backend.sendScheduledMessageNow(item.id)
        let posted = try await backend.loadMessages(in: room.conversation, before: nil)
        #expect(posted.count == 1 && posted.first?.attachments.map(\.name) == item.attachmentNames)
        await model.stop()
        await harness.service.shutdown()
    }

    @Test func anUploadFailureLeavesTheFileAvailableAndTheQueueEmpty() async throws {
        let harness = try await ClientHarness.make(uploads: true)
        let backend = harness.backend(harness.first)
        let store = try ChatStore.inMemory()
        let model = ChatSessionModel(store: store, engine: SyncEngine(backend: backend, store: store))
        try await model.start()
        try await waitFor { model.me == harness.first.selfID && !model.conversations.isEmpty }
        let room = Conversation.ID("same")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        model.select(room)
        model.stage([file("missing.txt", at: url, size: 1)], in: .conversation)
        let destination = MessageAddress(conversation: room)
        let empty = ComposedMessage(text: "")
        #expect(model.scheduleMessage(
            empty,
            draft: empty,
            at: Date(timeIntervalSince1970: 2_000_000_000),
            to: destination
        ) {})
        try await waitFor { model.schedules.submissions.isEmpty }
        #expect(model.stagedAttachments.map(\.state) == [.ready])
        #expect(model.schedules.receipts[destination] == nil)
        #expect(try await backend.scheduledMessages(after: nil).messages.isEmpty)
        await model.stop()
        await harness.service.shutdown()
    }

    private func file(_ name: String, at url: URL, size: Int) -> OutgoingAttachment {
        OutgoingAttachment(id: name, file: url, name: name, contentType: "text/plain", byteSize: size)
    }

    private func waitFor(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(predicate())
    }
}
