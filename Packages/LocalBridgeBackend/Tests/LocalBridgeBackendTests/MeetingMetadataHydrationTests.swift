import ChatKit
import Foundation
import GChatBridgeCore
import SwiftProtobuf
import Testing
@testable import LocalBridgeBackend

@Suite(.timeLimit(.minutes(1)))
struct MeetingMetadataHydrationTests {
    @Test func reducedWorldReturnsImmediatelyThenDetailEventsGroupWithoutOpeningChats() async throws {
        let transport = MeetingDetailTransport()
        let backend = try await connected(transport)
        let events = MeetingEventLog()
        let reader = Task { for await event in backend.events {
            await events.record(event)
        } }
        let world = try await backend.loadConversations()
        #expect(world.count == 2 && world.allSatisfy { $0.kind == .meetChat && $0.meeting == nil })
        try await wait { await transport.active == 2 }
        _ = try await backend.loadConversations()
        #expect(await transport.requests == 2)
        await transport.release()
        try await wait { await events.count == 2 }
        let enriched = try await backend.loadConversations()
        #expect(await transport.requests == 2)
        #expect(MeetingSeries.build(enriched).count == 1)
        #expect(MeetingSeries.build(enriched).first?.occurrences.count == 2)
        #expect(await events.meetings.count == 2)
        reader.cancel()
        await backend.disconnect()
    }

    @Test func requestsAreBoundedAndOnlyMetadataChangesInvalidateFreshResults() async throws {
        let transport = MeetingDetailTransport(count: 14)
        await transport.setUnsupported()
        let backend = try await connected(transport)
        _ = try await backend.loadConversations()
        try await wait { await transport.active == 6 }
        #expect(await transport.requests == 6)
        await transport.release()
        try await wait { await backend.meetingMetadata.task == nil }
        #expect(await transport.requests == 14)
        #expect(await transport.maximum <= 6)
        _ = try await backend.loadConversations()
        #expect(await transport.requests == 14)
        await transport.revise()
        _ = try await backend.loadConversations()
        try await wait { await backend.meetingMetadata.task == nil }
        #expect(await transport.requests == 14)
        await transport.revise(metadataChanged: true)
        _ = try await backend.loadConversations()
        try await wait { await backend.meetingMetadata.task == nil }
        #expect(await transport.requests == 28)
        await backend.disconnect()
    }

    @Test func completeWorldNeedsNoDetailRequest() async throws {
        let transport = MeetingDetailTransport(count: 1)
        await transport.supplyWorldMetadata()
        let backend = try await connected(transport)
        let world = try await backend.loadConversations()
        #expect(world.first?.meeting != nil)
        #expect(await backend.meetingMetadata.pending.isEmpty)
        #expect(await backend.meetingMetadata.task == nil)
        #expect(await transport.requests == 0)
        await backend.disconnect()
    }

    @Test func changedWorldWhileDetailIsInFlightReschedulesTheCurrentRevision() async throws {
        let transport = MeetingDetailTransport(count: 1)
        let backend = try await connected(transport)
        _ = try await backend.loadConversations()
        try await wait { await transport.active == 1 }
        await transport.revise()
        _ = try await backend.loadConversations()
        await transport.release()
        try await wait { await backend.meetingMetadata.task == nil }
        #expect(await transport.requests == 2)
        let cached = await backend.meetingMetadata.cache[.init("space/meeting-0")]
        #expect(cached?.key.revision == 2)
        #expect(cached?.meeting != nil)
        await backend.disconnect()
    }

    @Test func failedDetailsRetryOnNextWorldLoad() async throws {
        let transport = MeetingDetailTransport(count: 1)
        await transport.setFailure(true)
        await transport.release()
        let backend = try await connected(transport)
        _ = try await backend.loadConversations()
        try await wait { await backend.meetingMetadata.task == nil }
        #expect(await backend.meetingMetadata.cache.isEmpty)
        await transport.setFailure(false)
        _ = try await backend.loadConversations()
        try await wait { await backend.meetingMetadata.task == nil }
        #expect(await transport.requests == 2)
        #expect(await backend.meetingMetadata.cache.count == 1)
        await backend.disconnect()
    }

    @Test(arguments: ["disconnect", "remove", "mismatch"])
    func lateOrWrongDetailCannotPublishMetadata(action: String) async throws {
        let transport = MeetingDetailTransport(count: 1)
        if action == "mismatch" {
            await transport.mismatch()
        }
        let backend = try await connected(transport)
        let events = MeetingEventLog()
        let reader = Task { for await event in backend.events {
            await events.record(event)
        } }
        _ = try await backend.loadConversations()
        try await wait { await transport.active == 1 }
        if action == "disconnect" {
            await backend.disconnect()
        } else if action == "remove" {
            await transport.removeAll()
            _ = try await backend.loadConversations()
        }
        await transport.release()
        try await wait { await transport.active == 0 }
        try await wait { await backend.meetingMetadata.task == nil }
        #expect(await backend.meetingMetadata.cache.isEmpty)
        #expect(await events.isEmpty)
        reader.cancel()
        await backend.disconnect()
    }

    private func connected(_ transport: MeetingDetailTransport) async throws -> LocalBridgeBackend {
        let backend = LocalBridgeBackend(cookies: SearchBackendSupport.cookies, transport: transport)
        try await backend.connect()
        try await SearchBackendSupport.waitForSelf(backend)
        return backend
    }

    private func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await condition())
    }
}
