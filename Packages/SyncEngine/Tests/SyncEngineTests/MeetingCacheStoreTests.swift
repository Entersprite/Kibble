import ChatKit
import Foundation
import GRDB
import Testing
@testable import SyncEngine

@Suite(.timeLimit(.minutes(1)))
struct MeetingCacheStoreTests {
    let id = Conversation.ID("meeting")
    var value: Conversation {
        Conversation(id: id, kind: .meetChat, meeting: .init(
            seriesID: .init("parent"), occurrenceID: "instance", seriesTitle: "Planning",
            scheduledStart: Date(timeIntervalSince1970: 100)
        ))
    }

    @Test func savedMetadataSurvivesReopeningAndReducedSnapshotsUntilExplicitWithdrawal() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let first = try ChatStore.onDisk(at: url.path)
        try first.apply([.upsertConversation(value)])
        let reopened = try ChatStore.onDisk(at: url.path)
        let backend = GatedHistoryBackend(world: [], needsMentionBackfill: false)
        let engine = SyncEngine(backend: backend, store: reopened)
        let reduced = Conversation(id: id, kind: .meetChat, title: "Fresh summary")
        try await engine.applyConversationSnapshot([reduced])
        #expect(try reopened.conversations().first?.meeting == value.meeting)
        await engine.handle(.meetingMetadataChanged(conversationID: id, meeting: nil))
        try await engine.applyConversationSnapshot([reduced])
        #expect(try reopened.conversations().first?.meeting == nil)
        try reopened.apply([.upsertConversation(value)])
        try await engine.applyConversationSnapshot([Conversation(id: id, kind: .space)])
        #expect(try reopened.conversations().first?.meeting == nil)
    }

    @Test func schema18UpgradesWithoutLosingSavedMeetingMetadata() throws {
        let database = try DatabaseQueue()
        try Schema.migrator.migrate(database, upTo: "v18")
        try database.write { db in try ChatStore.upsert(value, in: db) }
        let store = try ChatStore(database)
        #expect(try store.conversations().first?.meeting == value.meeting)
        let loading = try database.read { db in
            try Bool.fetchOne(db, sql: "SELECT meetingMetadataLoading FROM syncState WHERE id = 1")
        }
        #expect(loading == false)
    }

    @MainActor
    @Test func loadingFlowsThroughTheSingleConsumerAndClearsOnStopAndRelaunch() async throws {
        let store = try ChatStore.inMemory()
        let backend = GatedHistoryBackend(world: [], needsMentionBackfill: false)
        let model = ChatSessionModel(store: store, engine: SyncEngine(backend: backend, store: store))
        try await model.start()
        await backend.emit(.meetingMetadataLoadingChanged(isLoading: true))
        try await wait { model.isLoadingMeetingMetadata }
        await backend.emit(.meetingMetadataLoadingChanged(isLoading: false))
        try await wait { !model.isLoadingMeetingMetadata }
        await backend.emit(.meetingMetadataLoadingChanged(isLoading: true))
        try await wait { model.isLoadingMeetingMetadata }
        await model.stop()
        #expect(!model.isLoadingMeetingMetadata)
        try store.apply([.clearEphemeralState])
        var iterator = store.observeMeetingMetadataLoading().makeAsyncIterator()
        #expect(try await iterator.next() == false)
    }

    @MainActor
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition())
    }
}
