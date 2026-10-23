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

    /// The demo's records are history in conversations Alex belongs to, and
    /// none of them moves a conversation's activity or newest message.
    @Test func theDemoCallHistoryAddsRecordsWithoutMovingAnyConversation() async throws {
        let base = FixtureWorld.acme
        let world = base.withDemoCallHistory()
        #expect(world.conversations == base.conversations)
        #expect(world.startedAt == base.startedAt)
        #expect(world.messages.count == base.messages.count + Acme.callRecords.count)
        let sorted = world.messages.map(\.createdAt)
        #expect(sorted == sorted.sorted())
        for record in Acme.callRecords {
            let conversation = try #require(world.conversations.first { $0.id == record.conversationID })
            #expect(conversation.members.contains(world.me))
            let newest = try #require(base.messages.filter { $0.conversationID == record.conversationID }
                .map(\.createdAt).max())
            #expect(record.createdAt < newest)
        }
        let backend = FakeBackend(world: world)
        try await backend.connect()
        let page = try await backend.callHistory(.init())
        #expect(page.messages.map(\.id.rawValue) == [
            "msg:call-5",
            "msg:call-4",
            "msg:call-3",
            "msg:call-2",
            "msg:call-1"
        ])
        #expect(try await FakeBackend(world: base.withDemoCallHistory()).connectThenRead() == page)
    }
}

private extension FakeBackend {
    func connectThenRead() async throws -> CallHistoryPage {
        try await connect()
        return try await callHistory(.init())
    }
}
