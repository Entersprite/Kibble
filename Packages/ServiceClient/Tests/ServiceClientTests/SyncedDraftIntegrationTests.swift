import ChatAPI
import ChatKit
import Foundation
import SyncEngine
import Testing

@Suite(.timeLimit(.minutes(1)))
struct SyncedDraftIntegrationTests {
    @Test func writesAreAccountBoundAndReplayTheOriginalAcknowledgement() async throws {
        let harness = try await ClientHarness.make(seedSyncedDrafts: true)
        let first = harness.backend(harness.first)
        let second = harness.backend(harness.second)
        try await first.connect()
        try await second.connect()

        let room = ComposerDraftAddress(conversation: .init("same"))
        let firstPage = try await first.syncedDrafts(at: room, after: nil)
        let secondPage = try await second.syncedDrafts(at: room, after: nil)
        let firstDraft = try #require(firstPage.drafts.first)
        let secondDraft = try #require(secondPage.drafts.first)
        let edit = ComposedMessage(text: "My edit")
        let foreign = SyncedDraftChange(address: room, previous: secondDraft, body: edit)
        let refused = try await first.writeSyncedDraft(foreign, operationID: ClientOperationID.make())
        #expect(refused == SyncedDraftWriteResult(applied: false, current: firstDraft))

        let original = SyncedDraftChange(address: room, previous: firstDraft, body: edit)
        let operation = ClientOperationID.make()
        let saved = try await first.writeSyncedDraft(original, operationID: operation)
        #expect(saved.applied && saved.current?.body == edit)
        let reread = try await first.syncedDrafts(at: room, after: nil)
        #expect(reread.drafts.first == saved.current)

        let clear = SyncedDraftChange(address: room, previous: saved.current, body: nil)
        let cleared = try await first.writeSyncedDraft(clear, operationID: ClientOperationID.make())
        #expect(cleared == SyncedDraftWriteResult(applied: true, current: nil))
        #expect(try await first.writeSyncedDraft(original, operationID: operation) == saved)
        #expect(try await first.syncedDrafts(at: room, after: nil).drafts.isEmpty)
        #expect(try await second.syncedDrafts(at: room, after: nil).drafts == [secondDraft])
        await first.disconnect()
        await second.disconnect()
        await harness.service.shutdown()
    }

    @Test func readsTheBoundAccountsDraftAtTheExactComposerAddress() async throws {
        let harness = try await ClientHarness.make(seedSyncedDrafts: true)
        let first = harness.backend(harness.first)
        let second = harness.backend(harness.second)
        try await first.connect()
        try await second.connect()

        let room = ComposerDraftAddress(conversation: .init("same"))
        let thread = ComposerDraftAddress(conversation: room.conversation, thread: .init("topic"))
        let firstRoom = try await first.syncedDrafts(at: room, after: nil)
        let secondRoom = try await second.syncedDrafts(at: room, after: nil)
        let firstThread = try await first.syncedDrafts(at: thread, after: nil)
        #expect(firstRoom.drafts.map(\.id) == secondRoom.drafts.map(\.id))
        #expect(firstRoom.drafts.map(\.body.text) == ["First"])
        #expect(secondRoom.drafts.map(\.body.text) == ["Second"])
        #expect(firstRoom.drafts.map(\.id.address) == [room])
        #expect(firstThread.drafts.map(\.id.address) == [thread])
        #expect(try await first.syncedDrafts(at: nil, after: nil).drafts == firstRoom.drafts + firstThread
            .drafts)

        let invalid = ComposerDraftAddress(conversation: room.conversation, thread: .init(""))
        await #expect(throws: ServiceFailure.invalidRequest) {
            try await first.syncedDrafts(at: invalid, after: nil)
        }
        await first.disconnect()
        await second.disconnect()
        await harness.service.shutdown()
    }

    @Test func sendAndItsReplayConsumeOnlyTheBoundAccountsExactDraft() async throws {
        let harness = try await ClientHarness.make(seedSyncedDrafts: true)
        let first = harness.backend(harness.first)
        let second = harness.backend(harness.second)
        try await first.connect()
        try await second.connect()
        let room = ComposerDraftAddress(conversation: .init("same"))
        let thread = ComposerDraftAddress(conversation: room.conversation, thread: .init("topic"))
        let draft = try #require(await first.syncedDrafts(at: room, after: nil).drafts.first)
        let otherDraft = try #require(await second.syncedDrafts(at: room, after: nil).drafts.first)
        let threadDraft = try #require(await first.syncedDrafts(at: thread, after: nil).drafts.first)
        let body = "Sent from a saved draft"
        let command = ChatCommand.sendMessage(
            conversationID: room.conversation, threadID: nil, text: body, localID: ClientOperationID.make()
        )

        await #expect(throws: ServiceFailure.invalidRequest) {
            try await first.send(command, consuming: threadDraft)
        }
        #expect(try await first.send(command, consuming: draft))
        #expect(try await first.send(command, consuming: draft))
        #expect(try await first.syncedDrafts(at: room, after: nil).drafts.isEmpty)
        #expect(try await first.syncedDrafts(at: thread, after: nil).drafts == [threadDraft])
        #expect(try await second.syncedDrafts(at: room, after: nil).drafts == [otherDraft])
        let posted = try await first.loadMessages(in: room.conversation, before: nil)
        #expect(posted.filter { $0.text == body }.count == 1)
        await first.disconnect()
        await second.disconnect()
        await harness.service.shutdown()
    }

    @MainActor
    @Test func stagedCaptionConsumesItsDraftAndPostsRemainingFilesWithoutRepeatingText() async throws {
        let harness = try await ClientHarness.make(uploads: true, seedSyncedDrafts: true)
        let backend = harness.backend(harness.first)
        let store = try ChatStore.inMemory()
        let model = ChatSessionModel(store: store, engine: SyncEngine(backend: backend, store: store))
        try await model.start()
        try await waitFor { model.me == harness.first.selfID && !model.conversations.isEmpty }
        let address = ComposerDraftAddress(conversation: .init("same"))
        let draft = try #require(await backend.syncedDrafts(at: address, after: nil).drafts.first)
        model.select(address.conversation)

        let caption = ComposedMessage(text: "Staged caption")
        let forged = ChatCommand.sendMessage(
            conversationID: address.conversation, threadID: nil, text: caption.text,
            localID: ClientOperationID.make(),
            attachments: [.init(id: "unissued", name: "unissued.txt", contentType: "text/plain")]
        )
        await #expect(throws: ServiceFailure.notAuthorized) {
            try await backend.send(forged, consuming: draft)
        }
        #expect(try await backend.syncedDrafts(at: address, after: nil).drafts == [draft])

        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bytes = Data("attachment fixture".utf8)
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        model.stage(["first", "second"].map { name in
            OutgoingAttachment(
                id: name,
                file: file,
                name: "\(name).txt",
                contentType: "text/plain",
                byteSize: bytes.count
            )
        }, in: .conversation)
        var receipts: [Bool] = []
        model.send(caption, in: address.conversation, consuming: draft) { receipts.append($0) }
        try await waitFor { model.stagedAttachments.isEmpty && !receipts.isEmpty }
        #expect(receipts == [true])
        #expect(try await backend.syncedDrafts(at: address, after: nil).drafts.isEmpty)
        let posted = try await backend.loadMessages(in: address.conversation, before: nil)
        #expect(posted.count == 2)
        #expect(posted.first { $0.attachments.first?.name == "first.txt" }?.text == caption.text)
        #expect(posted.first { $0.attachments.first?.name == "second.txt" }?.text == "")
        await model.stop()
        await harness.service.shutdown()
    }

    @MainActor
    @Test func confirmedGroupMembershipAdditionConsumesTheExactDraftWithOnePost() async throws {
        let harness = try await ClientHarness.make(
            seedSyncedDrafts: true,
            conversationKind: .groupDirectMessage
        )
        let backend = harness.backend(harness.first)
        let store = try ChatStore.inMemory()
        let model = ChatSessionModel(store: store, engine: SyncEngine(backend: backend, store: store))
        try await model.start()
        try await waitFor { model.me == harness.first.selfID && !model.conversations.isEmpty }
        let address = ComposerDraftAddress(conversation: .init("same"))
        let draft = try #require(await backend.syncedDrafts(at: address, after: nil).drafts.first)
        model.select(address.conversation)
        let peer = Member.ID("peer")
        let message = ComposedMessage(
            text: "@Peer hello", mentions: [Mention(target: .user(peer), start: 0, length: 5)]
        )

        var receipts: [Bool] = []
        model.addAndSend(message, adding: [peer], at: address, consuming: draft) { receipts.append($0) }
        try await waitFor { !receipts.isEmpty }
        #expect(receipts == [true])
        #expect(try await backend.syncedDrafts(at: address, after: nil).drafts.isEmpty)
        #expect(try await backend.conversationDetails(address.conversation).conversation.members
            .contains(peer))
        let posted = try await backend.loadMessages(in: address.conversation, before: nil)
        #expect(posted.map(\.text) == [message.text])
        #expect(posted.first?.mentions == message.mentions)
        await model.stop()
        await harness.service.shutdown()
    }

    @MainActor
    @Test func serializedUnsentChangesRefreshTheOpenComposerAndQueue() async throws {
        let harness = try await ClientHarness.make(seedSyncedDrafts: true)
        let first = harness.backend(harness.first)
        let second = harness.backend(harness.second)
        let store = try ChatStore.inMemory()
        let model = ChatSessionModel(store: store, engine: SyncEngine(backend: first, store: store))
        try await model.start()
        try await second.connect()
        try await waitFor { !model.conversations.isEmpty }
        let room = ComposerDraftAddress(conversation: .init("same"))
        let thread = ComposerDraftAddress(conversation: room.conversation, thread: .init("topic"))
        model.select(room.conversation)
        var changes: [ComposerDraftAddress] = []
        model.refreshOpenDraft = { changes.append($0) }

        try await updateDraft(at: thread, using: first)
        try await updateDraft(at: room, using: second)
        try await updateDraft(at: room, using: first)
        try await waitFor { !changes.isEmpty }
        #expect(changes == [room])

        model.showScheduledMessages()
        try await waitFor { !model.schedules.isLoading }
        let queued = try await first.scheduleMessage(
            in: room.conversation, thread: nil, body: ComposedMessage(text: "Next schedule"),
            at: Date(timeIntervalSince1970: 2_000_000_000)
        )
        try await waitFor { model.schedules.messages == [queued] }
        #expect(changes == [room])
        await model.stop()
        await second.disconnect()
        await harness.service.shutdown()
    }

    private func updateDraft(at address: ComposerDraftAddress, using backend: some ChatBackend) async throws {
        let previous = try #require(await backend.syncedDrafts(at: address, after: nil).drafts.first)
        let change = SyncedDraftChange(
            address: address,
            previous: previous,
            body: .init(text: "Revised draft")
        )
        let result = try await backend.writeSyncedDraft(change, operationID: ClientOperationID.make())
        try #require(result.applied)
    }

    @MainActor
    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }
}
