import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import SyncEngine

@Suite(.timeLimit(.minutes(1)))
struct ConversationActivityWatchTests {
    @Test func receivingIsCapabilityGatedAndIndependentOfSharing() async throws {
        let store = try ChatStore.inMemory()
        var capabilities = Capabilities.fixture
        capabilities.receivesTypingState = false
        let unsupported = RecordingBackend(capabilities: capabilities)
        let gated = SyncEngine(backend: unsupported, store: store)
        await gated.watchConversationActivity(Conversation.ID("conversation"))
        #expect(await unsupported.activityWatches.isEmpty)
        let backend = RecordingBackend()
        let engine = SyncEngine(backend: backend, store: store)
        await engine.setGhostMode(true)
        engine.typingPrivacy.set(nil)
        let accepted = await engine
            .submit(.watchConversationActivity(conversationID: Conversation.ID("conversation")))
        #expect(accepted)
        #expect(await backend.activityWatches == [Conversation.ID("conversation")])
    }

    @MainActor
    @Test func selectionReconnectAndClearUpdateTheReceiveInterest() async throws {
        let backend = RecordingBackend()
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let model = ChatSessionModel(store: store, engine: engine)
        let first = Conversation.ID("first")
        let second = Conversation.ID("second")
        model.select(first)
        await model.activityWatchTask?.value
        #expect(await backend.activityWatches == [first])
        // No settling between these selections: the canceled task must never publish the old interest.
        model.select(Conversation.ID("superseded"))
        model.select(second)
        await model.activityWatchTask?.value
        #expect(await backend.activityWatches.last == second)
        model.catchUpIfReconnected(.reconnecting(attempt: 1, issue: nil, detail: nil))
        model.catchUpIfReconnected(.connected)
        await model.activityWatchTask?.value
        #expect(await backend.activityWatches.suffix(2) == [second, second])
        model.clearSelection()
        await model.activityWatchTask?.value
        let watches = await backend.activityWatches
        #expect(watches.count == 4)
        #expect(watches[3] == nil)
        model.select(first)
        await model.stop()
        #expect(model.activityWatchTask == nil)
        #expect(await backend.activityWatches.count == 4)
    }
}
