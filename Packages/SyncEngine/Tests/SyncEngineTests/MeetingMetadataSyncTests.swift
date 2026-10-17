import ChatKit
import Foundation
import Testing
@testable import SyncEngine

@Suite(.timeLimit(.minutes(1)))
struct MeetingMetadataSyncTests {
    let id = Conversation.ID("meeting")
    var metadata: MeetingOccurrence {
        .init(
            seriesID: .init("series"),
            occurrenceID: "instance",
            seriesTitle: "Planning",
            scheduledStart: Date(timeIntervalSince1970: 100)
        )
    }

    @Test func detailEventBeforeWorldSurvivesSnapshotAndBuildsSeriesThroughTheConsumer() async throws {
        let store = try ChatStore.inMemory()
        let backend = GatedHistoryBackend(world: [], needsMentionBackfill: false)
        let engine = SyncEngine(backend: backend, store: store)
        try await engine.start()
        await backend.emit(.meetingMetadataChanged(conversationID: id, meeting: metadata))
        await backend.emit(.conversationsChanged([Conversation(id: id, kind: .meetChat)]))
        try await wait { try store.conversations().first?.meeting == metadata }
        #expect(try MeetingSeries.build(store.conversations()).first?.latest.id == id)
        await backend.setWorld([Conversation(id: id, kind: .meetChat, title: "Reduced refresh")])
        await engine.perform(.reloadConversations)
        #expect(try store.conversations().first?.meeting == metadata)
        await engine.stop()
        #expect(await engine.meetingMetadataUpdates.isEmpty)
    }

    @Test func metadataUpdatePreservesReadActivityMembershipAndOtherConversationFields() async throws {
        let store = try ChatStore.inMemory()
        let backend = GatedHistoryBackend(world: [], needsMentionBackfill: false)
        let engine = SyncEngine(backend: backend, store: store)
        var value = Conversation(id: id, kind: .meetChat, title: "Current title")
        value.hasUnread = true; value.unreadCount = 4; value.members = [.init("member")]
        value.readPosition = Date(timeIntervalSince1970: 50)
        value.lastActivity = Date(timeIntervalSince1970: 150)
        try store.apply([.upsertConversation(value)])
        await engine.handle(.meetingMetadataChanged(conversationID: id, meeting: metadata))
        var expected = value; expected.meeting = metadata
        #expect(try store.conversations() == [expected])
        await engine.handle(.meetingMetadataChanged(conversationID: id, meeting: nil))
        #expect(try store.conversations() == [value])
        await engine.handle(.conversationUpdated(value))
        #expect(try store.conversations().first?.meeting == nil)
    }

    @Test func removedAndNonMeetingConversationsCannotBeResurrectedOrGrouped() async throws {
        let store = try ChatStore.inMemory()
        let backend = GatedHistoryBackend(world: [], needsMentionBackfill: false)
        let engine = SyncEngine(backend: backend, store: store)
        let direct = Conversation(id: .init("direct"), kind: .directMessage)
        try store.apply([.upsertConversation(direct)])
        await engine.handle(.meetingMetadataChanged(conversationID: direct.id, meeting: metadata))
        #expect(try store.conversations() == [direct])
        await engine.handle(.meetingMetadataChanged(conversationID: id, meeting: metadata))
        #expect(try store.conversations().count == 1)
        await engine.handle(.conversationRemoved(conversationID: id, historyBefore: nil))
        try await engine.applyConversationSnapshot([Conversation(id: id, kind: .meetChat), direct])
        #expect(try store.conversations().allSatisfy { $0.meeting == nil })
        #expect(await engine.meetingMetadataUpdates.isEmpty)
    }

    @Test func explicitWorldMetadataSupersedesAnOlderDetailOverlay() async throws {
        let store = try ChatStore.inMemory()
        let backend = GatedHistoryBackend(world: [], needsMentionBackfill: false)
        let engine = SyncEngine(backend: backend, store: store)
        await engine.handle(.meetingMetadataChanged(conversationID: id, meeting: metadata))
        var revised = metadata; revised.seriesTitle = "Renamed"
        let value = Conversation(id: id, kind: .meetChat, meeting: revised)
        try await engine.applyConversationSnapshot([value])
        #expect(try store.conversations().first?.meeting == revised)
        #expect(await engine.meetingMetadataUpdates.isEmpty)
    }

    private func wait(_ condition: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while try !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(try condition())
    }
}
