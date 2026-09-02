import ChatKit
import Foundation
import Testing
@testable import FixtureBackend

/// Reads, and the one write that has a completion a caller must be able to
/// await.
@Suite(.timeLimit(.minutes(1)))
struct QueryTests {
    private let dm = Conversation.ID("dm:1")
    private let space = Conversation.ID("space:1")

    /// A conversation with `count` messages, so paging has something to page.
    private func pagedWorld(count: Int) -> FixtureWorld {
        var world = FixtureWorld.minimal
        world.messages.removeAll { $0.conversationID == dm }
        let start = world.startedAt
        world.messages.append(
            contentsOf: (1 ... count).map { index in
                Message(
                    id: Message.ID("paged-\(index)"),
                    conversationID: dm,
                    threadID: MessageThread.ID("paged-topic-\(index)"),
                    sender: world.me,
                    text: "message \(index)",
                    createdAt: start.addingTimeInterval(Double(index))
                )
            }
        )
        return world
    }

    @Test func loadConversationsHandsBackTheWholeList() async throws {
        let backend = FakeBackend(world: .minimal)
        #expect(try await backend.loadConversations() == FixtureWorld.minimal.conversations)
    }

    /// Reads do not require a connection: the fixture world is local, and a UI
    /// developer should not have to connect to see a list.
    @Test func loadsDoNotRequireAConnection() async throws {
        let backend = FakeBackend(world: .minimal)
        #expect(try await backend.loadConversations().isEmpty == false)
        #expect(try await backend.loadMessages(in: dm, before: nil).isEmpty == false)
    }

    @Test func noCursorReturnsTheMostRecentPageOldestFirst() async throws {
        let backend = FakeBackend(world: pagedWorld(count: 10), pageSize: 4)
        let page = try await backend.loadMessages(in: dm, before: nil)
        #expect(page.map(\.text) == ["message 7", "message 8", "message 9", "message 10"])
    }

    @Test func aCursorReturnsThePageEndingJustBeforeIt() async throws {
        let backend = FakeBackend(world: pagedWorld(count: 10), pageSize: 4)
        let page = try await backend.loadMessages(in: dm, before: Message.ID("paged-7"))
        #expect(page.map(\.text) == ["message 3", "message 4", "message 5", "message 6"])
    }

    @Test func pagingBackwardsEventuallyRunsOutRatherThanRepeating() async throws {
        let backend = FakeBackend(world: pagedWorld(count: 10), pageSize: 4)
        let page = try await backend.loadMessages(in: dm, before: Message.ID("paged-1"))
        #expect(page.isEmpty)
    }

    /// A cursor the conversation does not contain is a client bug. Returning an
    /// empty page would hide it and read as "no more history".
    @Test func aCursorFromAnotherConversationThrows() async throws {
        let backend = FakeBackend(world: .minimal)
        await #expect(throws: ChatError.self) {
            try await backend.loadMessages(in: space, before: Message.ID("fixture-seed-1"))
        }
    }

    @Test func aCursorThatExistsNowhereThrows() async throws {
        let backend = FakeBackend(world: .minimal)
        await #expect(throws: ChatError.self) {
            try await backend.loadMessages(in: dm, before: Message.ID("no-such-message"))
        }
    }

    @Test func loadingAnUnknownConversationThrows() async throws {
        let backend = FakeBackend(world: .minimal)
        await #expect(throws: ChatError.self) {
            try await backend.loadMessages(in: Conversation.ID("space:nowhere"), before: nil)
        }
    }

    @Test func settingTheNotificationLevelUpdatesTheSnapshotAndAnnouncesIt() async throws {
        let backend = FakeBackend(world: .minimal)
        let collector = EventCollector(backend.events)
        try await backend.connect()
        _ = await collector.next(6)

        try await backend.setNotificationSetting(.less, for: space)

        guard case let .conversationUpdated(updated) = await collector.nextOne() else {
            Issue.record("expected conversationUpdated")
            return
        }
        #expect(updated.id == space)
        #expect(updated.notificationLevel == .less)
        let reloaded = try await backend.loadConversations().first { $0.id == space }
        #expect(reloaded?.notificationLevel == .less)
    }

    @Test func settingTheNotificationLevelWhileDisconnectedThrows() async throws {
        let backend = FakeBackend(world: .minimal)
        await #expect(throws: ChatError.transport("not connected")) {
            try await backend.setNotificationSetting(.less, for: space)
        }
    }

    @Test func settingTheNotificationLevelWithoutTheCapabilityThrows() async throws {
        let backend = FakeBackend(world: .minimal, capabilities: Capabilities(canSendMessages: true))
        try await backend.connect()
        await #expect(throws: ChatError.unsupported(capability: "canSetNotificationLevel")) {
            try await backend.setNotificationSetting(.less, for: space)
        }
    }

    @Test func settingTheNotificationLevelOnAnUnknownConversationThrows() async throws {
        let backend = FakeBackend(world: .minimal)
        try await backend.connect()
        await #expect(throws: ChatError.self) {
            try await backend.setNotificationSetting(.less, for: Conversation.ID("space:nowhere"))
        }
    }
}
