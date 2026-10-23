import ChatKit
import Foundation
import Testing
@testable import ChatPersistence
@testable import SyncEngine

struct ScrollTargetModelTests {
    @MainActor
    @Test func aScrollTargetIsReadyOnlyAfterItsOwnWindowContainsIt() async throws {
        let fixture = TranscriptWindowTests()
        let conversation = fixture.conversation
        func message(_ index: Int) -> Message {
            fixture.message(index)
        }
        let store = try ChatStore.inMemory()
        try store.apply((0 ..< 1000).map { .upsertMessage(message($0)) })
        let model = ChatSessionModel(
            store: store,
            engine: SyncEngine(backend: RecordingBackend(), store: store)
        )
        model.select(conversation)
        await settleAutoMarkRead(until: "the latest window arrives") { model.messages.count == 100 }
        #expect(!model.messages.contains { $0.id == message(100).id })
        model.scrollTarget = message(100).id
        #expect(model.isLoadingScrollTarget)
        await settleAutoMarkRead(until: "the target window arrives") { !model.isLoadingScrollTarget }
        #expect(model.messages.contains { $0.id == message(100).id })
        #expect(model.messages.count == 100)
        model.clearSelection()
        #expect(!model.isLoadingScrollTarget)
        await model.stop()
    }
}
