import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import ChatPersistence
@testable import SyncEngine

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct UnconfirmedDeliveryTests {
    @Test func uncertainReplyStaysInItsThreadAndNeverReturnsAsATopLevelDraft() async throws {
        let backend = DeliveryStatusBackend()
        let started = try await makeModel(backend)
        let model = started.model
        let thread = MessageThread.ID("original-thread")
        model.openThread(thread)
        model.sendReply(ComposedMessage(text: "Unconfirmed thread reply"))
        try await wait { model.messageDeliveryStatuses.values.contains(.unconfirmed) }
        let pending = try #require(try started.store.messageDeliveries().first)
        let message = try #require(try started.store.message(pending.messageID))
        #expect(message.isReply)
        #expect(message.threadID == thread)
        #expect(!model.messages.contains { $0.id == pending.messageID })
        #expect(model.failedDraft == nil)
        #expect(await backend.sends.count == 1)
        await model.stop()
    }

    @Test func uncertainAttachmentSendDoesNotReturnItsFileOrCaptionForAnotherSend() async throws {
        let backend = DeliveryStatusBackend()
        let started = try await makeModel(backend)
        let model = started.model
        let file = OutgoingAttachment(
            id: "file",
            file: URL(fileURLWithPath: "/nonexistent/file.png"),
            name: "file.png",
            contentType: "image/png",
            byteSize: 100
        )
        model.stage([file], in: .conversation)
        model.send(ComposedMessage(text: "Original caption"))
        try await wait {
            model.stagedAttachments.isEmpty && model.messageDeliveryStatuses.values.contains(.unconfirmed)
        }
        let pending = try #require(try started.store.messageDeliveries().first)
        let message = try #require(try started.store.message(pending.messageID))
        #expect(message.text == "Original caption")
        #expect(message.attachments.count == 1)
        #expect(model.failedDraft == nil)
        #expect(await backend.sends.count == 1)
        #expect(await backend.inner.uploads.count == 1)
        await model.stop()
    }

    @Test func optimisticPendingStatePrecedesDispatchAndCancellationKeepsItForReconciliation() async throws {
        let backend = DeliveryStatusBackend()
        await backend.holdSend()
        let started = try await makeModel(backend)
        let model = started.model
        let store = started.store
        model.send(ComposedMessage(text: "Original interrupted submission"))
        try await wait { await backend.heldSendCount == 1 }
        let pending = try #require(try store.messageDeliveries().first)
        #expect(pending.status == .sending)
        let sends = Array(model.sendTasks.values)
        await model.stop()
        await backend.releaseSend()
        for task in sends {
            await task.value
        }
        #expect(try store.messageDeliveries().first?.status == .sending)
        #expect(model.failedDraft == nil)
        #expect(await backend.sends.count == 1)
    }

    @Test func anExternalSubmissionReturningAfterStopCannotWriteIntoErasedState() async throws {
        let backend = DeliveryStatusBackend()
        await backend.holdSend()
        let started = try await makeModel(backend)
        let model = started.model
        let store = started.store
        let engine = started.engine
        let id = Message.ID("local/external")
        try store.apply([.upsertMessage(message(id, local: "external")), .beginMessageDelivery(id)])
        let submission = Task {
            await engine.submit(
                .sendMessage(
                    conversationID: pendingConversation,
                    threadID: nil,
                    text: "External",
                    localID: "external"
                ),
                undoing: [.removeMessage(id: id)]
            )
        }
        try await wait { await backend.heldSendCount == 1 }
        await model.stop()
        try store.erase()
        await backend.releaseSend()
        #expect(await submission.value == false)
        #expect(try store.lastError() == nil)
        #expect(try store.messageDeliveries().isEmpty)
    }

    @Test func failedStatusSaveAfterAcknowledgementCannotRetractOrRestoreASentMessage() async throws {
        let backend = DeliveryStatusBackend()
        await backend.acceptWithoutEcho()
        let started = try await makeModel(backend)
        let model = started.model
        let store = started.store
        try await store.database.write { db in
            try db.execute(sql: """
            CREATE TRIGGER refuse_status BEFORE UPDATE ON messageDelivery
            BEGIN SELECT RAISE(ABORT, 'refused'); END
            """)
        }
        model.send(ComposedMessage(text: "Accepted before local failure"))
        try await wait {
            let sends = await backend.sends
            return sends.count == 1 && model.sendTasks.isEmpty
        }
        #expect(model.failedDraft == nil)
        #expect(await backend.sends.count == 1)
        #expect(try store.messageDeliveries().count == 1)
        #expect(try store.messages(in: pendingConversation)
            .contains { $0.text == "Accepted before local failure" })
        try await store.database.write { db in try db.execute(sql: "DROP TRIGGER refuse_status") }
        await model.stop()
    }

    @Test func uncertainSendKeepsItsMessageWithoutReturningAResendableDraft() async throws {
        let backend = DeliveryStatusBackend()
        let started = try await makeModel(backend)
        let model = started.model
        let store = started.store
        model.send(ComposedMessage(text: "Keep this original send"))
        try await wait { model.messageDeliveryStatuses.values.contains(.unconfirmed) }
        #expect(model.failedDraft == nil)
        #expect(try store.messages(in: model.selected ?? Conversation.ID(""))
            .contains { $0.text == "Keep this original send" })
        #expect(await backend.sends.count == 1)
        await model.stop()
    }

    @Test func checkingOriginalStatusNeverResendsAndAnEchoRetiresPendingState() async throws {
        let backend = DeliveryStatusBackend()
        let started = try await makeModel(backend)
        let model = started.model
        let store = started.store
        model.send(ComposedMessage(text: "One provider operation"))
        try await wait { model.messageDeliveryStatuses.values.contains(.unconfirmed) }
        let pending = try #require(try store.messageDeliveries().first)
        await backend.setStatus(.unconfirmed)
        model.checkMessageDelivery(pending.messageID)
        try await wait { await backend.statusChecks.count == 1 && model.checkingMessageDeliveries.isEmpty }
        #expect(await backend.sends.count == 1)
        #expect(await backend.statusChecks == [pending.localID])
        await backend.setStatus(.sent)
        model.checkMessageDelivery(pending.messageID)
        try await wait { model.messageDeliveryStatuses[pending.messageID] == .sent }
        #expect(await backend.sends.count == 1)
        await backend.echo()
        try await wait {
            model.messageDeliveryStatuses.isEmpty && model.messages
                .contains { $0.id == Message.ID("canonical") }
        }
        #expect(try store.messageDeliveries().isEmpty)
        #expect(try store.message(pending.messageID) == nil)
        await model.stop()
    }

    @Test func restartedPendingSendBecomesUnconfirmedAndOnlyItsStatusIsQueried() async throws {
        let store = try ChatStore.inMemory()
        let id = Message.ID("local/interrupted")
        try store.apply([.upsertMessage(message(id, local: "interrupted")), .beginMessageDelivery(id)])
        let backend = DeliveryStatusBackend()
        let started = try await makeModel(backend, store: store)
        let model = started.model
        try await wait {
            let checks = await backend.statusChecks
            return model.messageDeliveryStatuses[id] == .unconfirmed && !checks.isEmpty
        }
        #expect(await backend.sends.isEmpty)
        #expect(await backend.statusChecks == ["interrupted"])
        await model.stop()
    }

    @Test func definiteRefusalRetractsItsPendingRowAndReturnsTheText() async throws {
        let backend = DeliveryStatusBackend()
        await backend.refuse()
        let started = try await makeModel(backend)
        let model = started.model
        let store = started.store
        model.send(ComposedMessage(text: "Definitely not submitted"))
        try await wait {
            model.failedDraft?.text == "Definitely not submitted" &&
                !model.messages.contains { $0.text == "Definitely not submitted" }
        }
        #expect(try store.messageDeliveries().isEmpty)
        #expect(!model.messages.contains { $0.text == "Definitely not submitted" })
        await model.stop()
    }

    @Test func localPersistenceRefusalPreventsProviderDispatch() async throws {
        let backend = DeliveryStatusBackend()
        let started = try await makeModel(backend)
        let model = started.model
        let store = started.store
        try await store.database.write { db in
            try db.execute(sql: """
            CREATE TRIGGER refuse_pending BEFORE INSERT ON messageDelivery
            BEGIN SELECT RAISE(ABORT, 'refused'); END
            """)
        }
        model.send(ComposedMessage(text: "Must stay local"))
        #expect(model.failedDraft?.text == "Must stay local")
        #expect(await backend.sends.isEmpty)
        #expect(try store.messageDeliveries().isEmpty)
        await model.stop()
    }

    @Test func lateStatusAfterStopCannotRepopulateErasedState() async throws {
        let backend = DeliveryStatusBackend()
        let started = try await makeModel(backend)
        let model = started.model
        let store = started.store
        model.send(ComposedMessage(text: "Will be erased"))
        try await wait { model.messageDeliveryStatuses.values.contains(.unconfirmed) }
        let pending = try #require(try store.messageDeliveries().first)
        await backend.holdStatus()
        model.checkMessageDelivery(pending.messageID)
        try await wait { await backend.heldStatusCount == 1 }
        let checks = Array(model.sendTasks.values)
        await model.stop()
        try store.erase()
        await backend.releaseStatus()
        for task in checks {
            await task.value
        }
        #expect(try store.messageDeliveries().isEmpty)
        #expect(try store.messages(in: pendingConversation).isEmpty)
    }

    private struct Started {
        let model: ChatSessionModel
        let store: ChatStore
        let engine: SyncEngine
    }

    private var pendingConversation: Conversation.ID {
        FixtureWorld.minimal.messages[0].conversationID
    }

    private func makeModel(_ backend: DeliveryStatusBackend, store supplied: ChatStore? = nil)
        async throws -> Started {
        let store = try supplied ?? ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let model = ChatSessionModel(store: store, engine: engine, me: FixtureWorld.minimal.me)
        try await model.start()
        try await wait { model.conversations.contains { $0.id == pendingConversation } }
        model.select(pendingConversation)
        return Started(model: model, store: store, engine: engine)
    }

    private func message(_ id: Message.ID, local: String) -> Message {
        Message(
            id: id,
            conversationID: pendingConversation,
            threadID: MessageThread.ID(""),
            sender: FixtureWorld.minimal.me,
            text: "Original interrupted send",
            createdAt: Date(),
            localID: local
        )
    }

    private func wait(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw ChatError.unknown("The expected delivery state did not arrive")
    }
}
