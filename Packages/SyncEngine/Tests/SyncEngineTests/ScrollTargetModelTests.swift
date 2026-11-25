import ChatKit
import Foundation
import GRDB
import Observation
import Testing
@testable import ChatPersistence
@testable import SyncEngine

struct ScrollTargetModelTests {
    @MainActor
    @Test(.timeLimit(.minutes(1)))
    func aScrollTargetIsReadyOnlyAfterItsOwnWindowContainsIt() async throws {
        let fixture = TranscriptWindowTests()
        let conversation = fixture.conversation
        let anchor = fixture.message(100).id
        let latest = fixture.message(999).id
        let store = try ChatStore.inMemory()
        let writes = (0 ..< 1000).map { StoreWrite.upsertMessage(fixture.message($0)) }
        try await store.database.write { db in try ChatStore.apply(writes, in: db) }
        let model = ChatSessionModel(
            store: store,
            engine: SyncEngine(backend: RecordingBackend(), store: store)
        )
        model.select(conversation)
        let latestWindow = await Observations { model.messages.map(\.id) }
            .first { @Sendable in $0.last == latest }
        let latestIDs = try #require(latestWindow)
        #expect(latestIDs.count == 100)
        #expect(!latestIDs.contains(anchor))

        model.scrollTarget = anchor
        #expect(model.isLoadingScrollTarget)
        let observed = await Observations {
            (loading: model.isLoadingScrollTarget, ids: model.messages.map(\.id))
        }.first { @Sendable in !$0.loading }
        let targetWindow = try #require(observed)
        #expect(targetWindow.ids.contains(anchor))
        #expect(targetWindow.ids.count == 100)
        model.clearSelection()
        #expect(!model.isLoadingScrollTarget)
        await model.stop()
    }
}
