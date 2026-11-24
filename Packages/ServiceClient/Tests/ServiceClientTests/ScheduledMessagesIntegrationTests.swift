import ChatKit
import Foundation
import SyncEngine
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ScheduledMessagesIntegrationTests {
    @MainActor
    @Test func switchingToTheQueueDoesNotRetargetAConfirmedComposerSubmission() async throws {
        let harness = try await ClientHarness.make()
        let store = try ChatStore.inMemory()
        let model = ChatSessionModel(
            store: store, engine: SyncEngine(backend: harness.backend(harness.first), store: store)
        )
        try await model.start()
        let deadline = ContinuousClock.now + .seconds(5)
        while model.conversations.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let conversation = try #require(model.conversations.first)
        model.select(conversation.id)
        let destination = MessageAddress(conversation: conversation.id)
        let draft = ComposedMessage(text: "  Original draft  ")
        let body = ComposedMessage(text: "Original draft")
        var accepted = false
        let schedule = model.scheduleMessage(
            body, draft: draft, at: Date(timeIntervalSince1970: 2_000_000_000), to: destination
        ) { accepted = true }
        #expect(schedule)
        model.showScheduledMessages()
        let resultDeadline = ContinuousClock.now + .seconds(5)
        while !accepted || model.schedules.messages.isEmpty, ContinuousClock.now < resultDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(accepted)
        #expect(model.selected == nil)
        #expect(model.schedules.receipts[destination]?.body == draft)
        #expect(model.schedules.messages.map(\.body) == [body])
        await model.stop()
        await harness.service.shutdown()
    }

    @Test func changesUseTheSerializedQueueAndStayWithTheOriginalAccount() async throws {
        let harness = try await ClientHarness.make()
        let first = harness.backend(harness.first)
        let second = harness.backend(harness.second)
        try await first.connect()
        try await second.connect()
        let conversation = Conversation.ID("same")
        let initialTime = Date(timeIntervalSince1970: 2_000_000_000)
        let revisedTime = initialTime.addingTimeInterval(3600)
        let firstBody = ComposedMessage(text: "Scheduled sample")

        let created = try await first.scheduleMessage(
            in: conversation,
            thread: nil,
            body: firstBody,
            at: initialTime
        )
        #expect(created.id.conversation == conversation && created.deliveryTime == initialTime)
        #expect(try await second.scheduledMessages(after: nil).messages.isEmpty)
        let secondItem = try await second.scheduleMessage(
            in: conversation, thread: nil, body: ComposedMessage(text: "Second account"), at: initialTime
        )
        #expect(secondItem.id != created.id)
        await #expect(throws: (any Error).self) {
            try await second.cancelScheduledMessage(created.id)
        }
        #expect(try await second.scheduledMessages(after: nil).messages == [secondItem])
        #expect(try await first.scheduledMessages(after: nil).messages == [created])

        let edited = try await first.editScheduledMessage(
            created.id,
            body: ComposedMessage(text: "Revised sample")
        )
        #expect(edited.body.text == "Revised sample" && edited.deliveryTime == initialTime)
        let moved = try await first.rescheduleMessage(created.id, at: revisedTime)
        #expect(moved.body == edited.body && moved.deliveryTime == revisedTime)
        #expect(try await first.scheduledMessages(after: nil).messages == [moved])
        #expect(try await first.loadMessages(in: conversation, before: nil)
            .allSatisfy { $0.text != moved.body.text })

        try await first.cancelScheduledMessage(created.id)
        #expect(try await first.scheduledMessages(after: nil).messages.isEmpty)
        await first.disconnect()
        await second.disconnect()
        await harness.service.shutdown()
    }

    @Test func sendNowConsumesAnItemOnceInItsOriginalAccount() async throws {
        let harness = try await ClientHarness.make()
        let first = harness.backend(harness.first)
        let second = harness.backend(harness.second)
        try await first.connect()
        try await second.connect()
        let conversation = Conversation.ID("same")
        let body = ComposedMessage(text: "Scheduled for immediate delivery")
        let queued = try await first.scheduleMessage(
            in: conversation, thread: nil, body: body, at: Date(timeIntervalSince1970: 2_000_000_000)
        )

        await #expect(throws: (any Error).self) { try await second.sendScheduledMessageNow(queued.id) }
        try await first.sendScheduledMessageNow(queued.id)
        #expect(try await first.scheduledMessages(after: nil).messages.isEmpty)
        await #expect(throws: (any Error).self) { try await first.sendScheduledMessageNow(queued.id) }
        let delivered = try await first.loadMessages(in: conversation, before: nil)
        #expect(delivered.filter { $0.text == body.text }.count == 1)
        let otherAccount = try await second.loadMessages(in: conversation, before: nil)
        #expect(otherAccount.allSatisfy { $0.text != body.text })
        await first.disconnect()
        await second.disconnect()
        await harness.service.shutdown()
    }

    @Test func convertsOnlyTheSavedVersionInTheBoundAccount() async throws {
        let harness = try await ClientHarness.make()
        let first = harness.backend(harness.first)
        let second = harness.backend(harness.second)
        try await first.connect()
        try await second.connect()
        let scope = ComposerDraftAddress(conversation: .init("same"), thread: .init("topic"))
        let saved = try await first.writeSyncedDraft(
            SyncedDraftChange(address: scope, previous: nil, body: ComposedMessage(text: "Local draft")),
            operationID: ClientOperationID.make()
        )
        let draft = try #require(saved.current)
        let delivered = ComposedMessage(text: "Scheduled draft")
        let date = Date(timeIntervalSince1970: 2_000_000_000)
        await #expect(throws: (any Error).self) {
            try await second.scheduleSavedDraft(draft, body: delivered, at: date)
        }
        #expect(try await first.syncedDrafts(at: scope, after: nil).drafts == [draft])
        let item = try await first.scheduleSavedDraft(draft, body: delivered, at: date)
        #expect(item.id.queueID == draft.id.record && item.id.thread == scope.thread)
        #expect(item.body == delivered)
        #expect(try await first.syncedDrafts(at: scope, after: nil).drafts.isEmpty)
        #expect(try await first.scheduledMessages(after: nil).messages == [item])
        #expect(try await second.scheduledMessages(after: nil).messages.isEmpty)
        await first.disconnect()
        await second.disconnect()
        await harness.service.shutdown()
    }
}
