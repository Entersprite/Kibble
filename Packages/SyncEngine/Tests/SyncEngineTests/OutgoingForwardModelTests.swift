import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import ChatPersistence
@testable import SyncEngine

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct OutgoingForwardModelTests {
    @Test func forwardingWithoutACommentUsesTheDestinationAndPreservesTheSourceAndDraft() async throws {
        var world = FixtureWorld.minimal
        let source = Message(
            id: .init("source"),
            conversationID: .init("space:1"),
            threadID: .init("source-thread"),
            sender: world.me,
            text: "Original",
            createdAt: world.startedAt
        )
        world.messages = [source]
        world.conversations.append(Conversation(id: .init("destination"), kind: .space, title: "Destination"))
        let backend = FakeBackend(world: world)
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let model = ChatSessionModel(store: store, engine: engine, me: world.me)
        try await model.start()
        try store.apply([.upsertMessage(source)])
        await settleAutoMarkRead(until: "destination loaded") {
            model.conversations.count == world.conversations.count && model.me != nil
        }
        model.select(source.conversationID)
        model.keepDraft(ComposedMessage(text: "Unsent draft"), in: source.conversationID)
        #expect(await model.forward(source.id, to: .init("destination"), comment: ""))
        await settleAutoMarkRead(until: "forward echo") {
            (try? store.messages(in: .init("destination")))?
                .contains {
                    $0.content?.forwarded != nil && $0.localID != nil && !$0.id.rawValue.hasPrefix("local/")
                } ==
                true
        }
        let received = try #require(store.messages(in: .init("destination")).first)
        #expect(received.text.isEmpty)
        #expect(received.content?.forwarded?.source.id == source.id)
        #expect(received.content?.forwarded?.source.text == "Original")
        #expect(received.content?.forwardSource == nil)
        #expect(model.selected == source.conversationID)
        #expect(model.failedDraft?.text == "Unsent draft")
        #expect(await !model.forward(.init("unknown"), to: .init("destination"), comment: "No"))
        await model.stop()
    }

    @Test func uncertainForwardsKeepOnePendingOperationAndRefusalsRemoveTheOptimisticCopy() async throws {
        for refused in [false, true] {
            let backend = DeliveryStatusBackend()
            if refused {
                await backend.refuse()
            }
            let store = try ChatStore.inMemory()
            let engine = SyncEngine(backend: backend, store: store)
            let model = ChatSessionModel(store: store, engine: engine, me: FixtureWorld.minimal.me)
            try await model.start()
            model.setActive(false)
            await settleAutoMarkRead(until: "conversations loaded") {
                !model.conversations.isEmpty && model.me != nil
            }
            let destination = try #require(model.conversations.first?.id)
            let source = Message(
                id: .init("source"),
                conversationID: destination,
                threadID: .init("thread"),
                sender: FixtureWorld.minimal.me,
                text: "Original",
                createdAt: FixtureWorld.minimal.startedAt
            )
            try store.apply([.upsertMessage(source)])
            #expect(await model.forward(source.id, to: destination, comment: "Comment") == !refused)
            #expect(await backend.sends.count == 1)
            let pending = try store.messageDeliveries()
            if refused {
                #expect(pending.isEmpty)
                #expect(try store.messages(in: destination)
                    .allSatisfy { !$0.id.rawValue.hasPrefix("local/") })
            } else {
                let delivery = try #require(pending.first)
                #expect(delivery.status == .unconfirmed)
                await model.checkMessageDelivery(delivery.messageID)
                #expect(await backend.sends.count == 1)
            }
            await model.stop()
        }
    }
}
