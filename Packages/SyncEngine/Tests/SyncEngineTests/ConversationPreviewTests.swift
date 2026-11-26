import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import SyncEngine

@Suite(.timeLimit(.minutes(1)))
struct ConversationPreviewTests {
    @MainActor @Test func previewsLoadWithoutJoiningOrWritingMessagesAndClearOnClose() async throws {
        let backend = FakeBackend()
        try await backend.connect()
        let store = try ChatStore.inMemory()
        let browser = ConversationBrowser(engine: SyncEngine(backend: backend, store: store))
        let page = try await backend.browseSpaces(.init(scope: .invitations), after: nil)
        let details = try #require(page.spaces.first)
        browser.showPreview(details)
        await browser.detailsTask?.value
        await browser.previewTask?.value
        #expect(browser.details?.membership == .invited)
        #expect(browser.preview?.messages.isEmpty == false)
        #expect(browser.preview?.members.isEmpty == false)
        #expect(!browser.isLoadingPreview)
        #expect(try store.conversations().isEmpty)
        #expect(try store.messages(in: details.conversation.id).isEmpty)
        browser.closePanel()
        #expect(browser.preview == nil)
        #expect(browser.previewError == nil)
        browser.stop()
        await backend.disconnect()
    }

    @MainActor @Test func aLatePreviewCannotRestoreAClosedPanel() async throws {
        let backend = HeldPreviewBackend()
        let store = try ChatStore.inMemory()
        let browser = ConversationBrowser(engine: SyncEngine(backend: backend, store: store))
        browser.openDetails(.init("space"))
        await browser.detailsTask?.value
        for _ in 0 ..< 200 where await !backend.held {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await backend.held)
        let pending = try #require(browser.previewTask)
        browser.closePanel()
        await backend.release()
        await pending.value
        #expect(browser.preview == nil)
        #expect(!browser.isLoadingPreview)
        #expect(browser.panelTarget == nil)
        #expect(try store.conversations().isEmpty)
        browser.stop()
    }

    @Test func aPreviewFromAnotherConversationIsRefused() async throws {
        let backend = HeldPreviewBackend(wrongConversation: true)
        let engine = try SyncEngine(backend: backend, store: ChatStore.inMemory())
        await #expect(throws: ChatError.self) {
            _ = try await engine.loadConversationPreview(.init("space"))
        }
    }
}

private actor HeldPreviewBackend: ChatBackend {
    nonisolated let capabilities = Capabilities(extendedFlags: ["conversationPreview"])
    nonisolated let events = AsyncStream<ChatEvent> { _ in }
    let wrongConversation: Bool
    var held: Bool {
        waiter != nil
    }

    private var waiter: CheckedContinuation<Void, Never>?

    init(wrongConversation: Bool = false) {
        self.wrongConversation = wrongConversation
    }

    func connect() {}
    func disconnect() {}
    func send(_: ChatCommand) {}
    func loadConversations() -> [Conversation] {
        []
    }

    func loadMessages(in _: Conversation.ID, before _: Message.ID?) -> [Message] {
        []
    }

    func setNotificationSetting(_: NotificationLevel, for _: Conversation.ID) {}
    func conversationDetails(_ id: Conversation.ID) -> ConversationDetails {
        ConversationDetails(conversation: Conversation(id: id, kind: .space), membership: .invited)
    }

    func conversationPreview(_ id: Conversation.ID) async -> ConversationPreview {
        if !wrongConversation {
            // Models a response already queued before cancellation.
            await withCheckedContinuation { waiter = $0 }
        }
        return ConversationPreview(messages: [Message(
            id: .init("m"), conversationID: wrongConversation ? .init("other") : id,
            threadID: .init("t"), sender: .init("sender"), text: "Preview",
            createdAt: Date(timeIntervalSince1970: 100)
        )])
    }

    func release() {
        waiter?.resume(); waiter = nil
    }
}
