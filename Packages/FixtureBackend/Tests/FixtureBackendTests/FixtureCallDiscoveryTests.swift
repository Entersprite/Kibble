import ChatKit
import Foundation
import Testing
@testable import FixtureBackend

struct FixtureCallDiscoveryTests {
    @Test func liveStateIsExplicitAndNeverInferredFromStartedHistory() async throws {
        var world = FixtureWorld.minimal
        let id = try #require(world.conversations.first).id
        world.messages = [Message(
            id: .init("call"), conversationID: id, threadID: .init("thread"), sender: world.me,
            text: "", createdAt: world.startedAt, callStatus: .started
        )]
        let backend = FakeBackend(world: world)
        try await backend.connect()
        let calls: any CallDiscoveryBackend = backend
        #expect(try await calls.callAvailability(in: id).status == .unknown("unavailable"))
        await backend.setCallAvailability(.init(
            conversationID: id, status: .active, checkedAt: .distantPast, reference: "opaque",
            participants: [.init(memberID: world.me)], totalParticipants: 1
        ))
        let active = try await calls.callAvailability(in: id)
        #expect(active.status == .active)
        #expect(active.checkedAt != .distantPast)
        #expect(active.participants?.first?.memberID == world.me)
        let unsupported = FakeBackend(world: world, capabilities: .init())
        try await unsupported.connect()
        await #expect(throws: ChatError.unsupported(capability: "callDiscovery")) {
            try await unsupported.callAvailability(in: id)
        }
    }
}
