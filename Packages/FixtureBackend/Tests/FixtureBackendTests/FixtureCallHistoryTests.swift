import ChatKit
import Foundation
import Testing
@testable import FixtureBackend

struct FixtureCallHistoryTests {
    @Test func callHistoryHasDeterministicPagingAndAnExplicitCapability() async throws {
        var world = FixtureWorld.minimal
        let conversation = try #require(world.conversations.first)
        world.messages = ["first", "second"].enumerated().map { index, id in
            Message(
                id: .init(id), conversationID: conversation.id, threadID: .init("thread"),
                sender: world.me, text: "", createdAt: world.startedAt.addingTimeInterval(Double(index)),
                callStatus: .started, callMetadata: .init(reference: "call")
            )
        }
        let first = FakeBackend(world: world)
        let second = FakeBackend(world: world)
        try await first.connect(); try await second.connect()
        let reader: any CallHistoryBackend = first
        let page = try await reader.callHistory(.init(limit: 1))
        #expect(page.messages.map(\.id.rawValue) == ["second"])
        #expect(try await second.callHistory(.init(limit: 1)) == page)
        #expect(try await first.callHistory(.init(cursor: page.nextCursor)).messages
            .map(\.id.rawValue) == ["first"])
        let unsupported = FakeBackend(world: world, capabilities: .init())
        try await unsupported.connect()
        await #expect(throws: ChatError.unsupported(capability: "callHistory")) {
            try await unsupported.callHistory()
        }
    }
}
