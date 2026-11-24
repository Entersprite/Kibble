import ChatKit
import FixtureBackend
import Testing
@testable import ChatPersistence
@testable import SyncEngine

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct StarredPagingTests {
    @Test func continuationSurvivesAnEmptyPageAndFailedRefreshKeepsTheLoadedWindow() async throws {
        let message = try #require(FixtureWorld.minimal.messages.first)
        let backend = StarredPageBackend(pages: [
            nil: .init(messages: [], nextCursor: "a"),
            "a": .init(messages: [message], nextCursor: "b")
        ])
        let store = try ChatStore.inMemory()
        let model = ChatSessionModel(store: store, engine: SyncEngine(backend: backend, store: store))
        try await model.start()
        await settleAutoMarkRead(until: "startup settled") { model.actedOnConnection == .connected }
        model.showStarredMessages()
        await settleAutoMarkRead(until: "the empty first page has a next cursor") {
            model.stars.hasMore && !model.stars.isLoading
        }
        #expect(model.stars.messages.isEmpty)
        model.loadMoreStarredMessages()
        await settleAutoMarkRead(until: "the second page arrives") { model.stars.messages == [message] }

        await backend.replacePages([nil: .init(messages: [], nextCursor: "a")])
        model.refreshStarredMessages()
        await settleAutoMarkRead(until: "the second refresh page failed") { model.stars.readFailed }
        #expect(model.stars.messages == [message])
        #expect(model.stars.hasMore)

        await backend.replacePages(["b": .init(messages: [], nextCursor: "a")])
        model.loadMoreStarredMessages()
        await settleAutoMarkRead(until: "a nonadjacent cursor repeat was refused") { model.stars.readFailed }
        #expect(model.stars.messages == [message])
        let requests = await backend.requests
        #expect(requests == [nil, "a", nil, "a", "b"])
        await model.stop()
    }
}

private actor StarredPageBackend: ChatBackend {
    let fixture = FakeBackend(world: .minimal)
    private var pages: [String?: StarredMessagesPage]
    private(set) var requests: [String?] = []

    init(pages: [String?: StarredMessagesPage]) {
        self.pages = pages
    }

    nonisolated var capabilities: Capabilities {
        fixture.capabilities
    }

    nonisolated var events: AsyncStream<ChatEvent> {
        fixture.events
    }

    func connect() async throws {
        try await fixture.connect()
    }

    func disconnect() async {
        await fixture.disconnect()
    }

    func send(_ command: ChatCommand) async throws {
        try await fixture.send(command)
    }

    func loadConversations() async throws -> [Conversation] {
        try await fixture.loadConversations()
    }

    func loadMessages(
        in conversation: Conversation.ID, before cursor: Message.ID?
    ) async throws -> [Message] {
        try await fixture.loadMessages(in: conversation, before: cursor)
    }

    func setNotificationSetting(_ level: NotificationLevel, for conversation: Conversation.ID) async throws {
        try await fixture.setNotificationSetting(level, for: conversation)
    }

    func replacePages(_ pages: [String?: StarredMessagesPage]) {
        self.pages = pages
    }

    func starredMessages(after cursor: String?) throws -> StarredMessagesPage {
        requests.append(cursor)
        guard let page = pages[cursor] else {
            throw ChatError.unknown("No fixture page for this cursor.")
        }
        return page
    }
}
