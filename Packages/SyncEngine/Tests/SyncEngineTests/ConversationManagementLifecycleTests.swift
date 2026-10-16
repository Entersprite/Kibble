import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import SyncEngine

private actor HeldManagementBackend: ChatBackend {
    nonisolated let capabilities = Capabilities.fixture
    nonisolated let events = AsyncStream<ChatEvent> { _ in }
    private var continuation: CheckedContinuation<ConversationCreationResult, Never>?
    var isHolding: Bool {
        continuation != nil
    }

    func connect() async throws {}
    func disconnect() async {}
    func send(_: ChatCommand) async throws {}
    func loadConversations() async throws -> [Conversation] {
        []
    }

    func loadMessages(in _: Conversation.ID, before _: Message.ID?) async throws -> [Message] {
        []
    }

    func setNotificationSetting(_: NotificationLevel, for _: Conversation.ID) async throws {}
    func createConversation(_: ConversationDraft) async throws -> ConversationCreationResult {
        // Deliberately ignores cancellation to model a response queued before teardown.
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume(returning: ConversationCreationResult(
            conversation: Conversation(id: .init("late"), kind: .space, title: "Late")
        ))
        continuation = nil
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ConversationManagementLifecycleTests {
    @Test func aCreationAnswerAfterStopCannotRestoreAnErasedStore() async throws {
        let backend = HeldManagementBackend()
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let task = Task { try await engine.createConversation(.init(kind: .space, name: "Late")) }
        for _ in 0 ..< 200 where await !backend.isHolding {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await backend.isHolding)
        await engine.stop()
        await backend.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try store.conversations().isEmpty)
    }

    @MainActor @Test func closingACreationPanelDoesNotClearTheDirectorySearch() async throws {
        let backend = FakeBackend()
        try await backend.connect()
        let engine = try SyncEngine(backend: backend, store: ChatStore.inMemory())
        let browser = ConversationBrowser(engine: engine)
        browser.showPage("space")
        browser.search("Coffee", scope: .discover)
        browser.beginCreation(.space)
        browser.searchPeople("person")
        browser.closePanel()
        #expect(browser.page == "space")
        #expect(browser.query == "Coffee")
        #expect(browser.scope == .discover)
        browser.stop()
        await backend.disconnect()
    }
}

extension ConversationManagementLifecycleTests {
    @MainActor @Test func organizationAndMembershipSurviveTheSeparateSpamPage() async throws {
        let backend = FakeBackend()
        try await backend.connect()
        let browser = try ConversationBrowser(engine: SyncEngine(
            backend: backend,
            store: ChatStore.inMemory()
        ))
        browser.showPage("space")
        await browser.queryTask?.value
        #expect(browser.scope == .discover && browser.organization == .all)
        browser.search("Partner", organization: .externalOnly)
        await browser.queryTask?.value
        let matching = browser.spaces.map(\.conversation.id)
        #expect(!matching.isEmpty)
        browser.showPage("spaceSpam")
        await browser.queryTask?.value
        #expect(browser.scope == .spamInvitations && browser.organization == .all)
        #expect(browser.query.isEmpty)
        #expect(!browser.spaces.isEmpty)
        browser.showPage("space")
        #expect(browser.query == "Partner" && browser.organization == .externalOnly)
        #expect(browser.scope == .discover)
        #expect(browser.spaces.map(\.conversation.id) == matching)
        browser.search("", scope: .all)
        await browser.queryTask?.value
        #expect(browser.organization == .externalOnly && browser.scope == .all)
        #expect(browser.error == nil)
        browser.stop()
        #expect(browser.organization == .all)
        await backend.disconnect()
    }

    @MainActor @Test(arguments: ["people", "directMessage"])
    func peopleSearchAlwaysQueriesTheDirectoryFromEitherEntryPoint(_ page: String) async throws {
        let backend = RecordingBackend()
        try await backend.connect()
        await backend.echoQueries(true)
        let browser = try ConversationBrowser(engine: SyncEngine(
            backend: backend,
            store: ChatStore.inMemory()
        ))
        browser.showPage(page)
        browser.search("ava")
        await browser.queryTask?.value
        #expect(browser.people.map(\.id) == [.init("ava")])
        #expect(browser.error == nil)
        browser.stop()
        await backend.disconnect()
    }

    @MainActor @Test func changingSpacesScopeReplacesJoinedResultsWithDiscoveryAndInvitations() async throws {
        let backend = FakeBackend()
        try await backend.connect()
        let browser = try ConversationBrowser(engine: SyncEngine(
            backend: backend,
            store: ChatStore.inMemory()
        ))
        browser.showPage("space")
        await browser.queryTask?.value
        #expect(browser.scope == .discover)
        #expect(browser.spaces.allSatisfy { $0.membership != .joined })
        browser.search("", scope: .joined)
        await browser.queryTask?.value
        let joined = Set(browser.spaces.map(\.conversation.id))
        #expect(!joined.isEmpty)
        #expect(browser.spaces.allSatisfy { $0.membership == .joined })
        browser.search("", scope: .discover)
        await browser.queryTask?.value
        #expect(browser.scope == .discover)
        #expect(!browser.spaces.isEmpty)
        #expect(browser.spaces
            .allSatisfy { !joined.contains($0.conversation.id) && $0.membership != .joined })
        browser.search("", scope: .invitations)
        await browser.queryTask?.value
        #expect(browser.scope == .invitations)
        #expect(!browser.spaces.isEmpty)
        #expect(browser.spaces.allSatisfy { $0.membership == .invited })
        browser.stop()
        await backend.disconnect()
    }

    @MainActor @Test func switchingToACachedPageRejectsThePreviousPagesLateSearch() async throws {
        let backend = RecordingBackend()
        try await backend.connect()
        await backend.holdSearches(true)
        await backend.echoQueries(true)
        let browser = try ConversationBrowser(engine: SyncEngine(
            backend: backend,
            store: ChatStore.inMemory()
        ))
        browser.showPage("groupDirectMessage")
        browser.showPage("people")
        browser.search("old-query")
        for _ in 0 ..< 200 where await backend.heldSearchCount == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await backend.heldSearchCount == 1)
        let pending = try #require(browser.queryTask)
        browser.showPage("groupDirectMessage")
        await backend.releaseHeldSearch()
        await pending.value
        #expect(browser.page == "groupDirectMessage")
        #expect(browser.query.isEmpty)
        #expect(browser.people.isEmpty)
        browser.stop()
        await backend.disconnect()
    }
}

extension ConversationManagementLifecycleTests {
    @MainActor @Test func stoppingErasesDirectoryQueriesAndPendingPanels() async throws {
        let backend = FakeBackend()
        try await backend.connect()
        let browser = try ConversationBrowser(engine: SyncEngine(
            backend: backend,
            store: ChatStore.inMemory()
        ))
        browser.showPage("people")
        browser.search("private-search@example.test")
        browser.beginCreation(.space)
        browser.searchPeople("private-person")
        browser.stop()
        #expect(browser.query.isEmpty)
        #expect(browser.page == nil)
        #expect(browser.lastPage == nil)
        #expect(browser.creationKind == nil)
        #expect(browser.panelTarget == nil)
        #expect(!browser.isSearchingPeople)
        #expect(browser.directorySnapshots.isEmpty)
        await backend.disconnect()
    }
}
