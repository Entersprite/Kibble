import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import ChatPersistence
@testable import SyncEngine

/// A conversation opened from Info, which the window opened rather than the
/// directory: Info closes and the conversation is selected, not left hidden
/// under the sheet.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct InfoOpensConversationTests {
    let space = Conversation.ID("space:1")
    let other = Member.ID("fixture-other")

    @Test func messagingAPersonFromInfoClosesItAndSelectsTheirChat() async throws {
        let backend = FakeBackend(world: .minimal)
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let model = ChatSessionModel(store: store, engine: engine, me: nil, markReadDebounce: .zero)
        try await model.start()
        model.openConversationDetails(space)
        await model.browser.detailsTask?.value
        #expect(model.browser.panelTarget == space)

        model.browser.create(ConversationDraft(kind: .directMessage, members: [other]))
        await model.browser.writeTask?.value

        #expect(model.browser.panelTarget == nil)
        #expect(model.browser.details == nil)
        let selected = try #require(model.selected)
        let chat = try #require(try store.conversations().first { $0.id == selected })
        #expect(chat.kind == .directMessage)
        #expect(chat.members.contains(other))
        await model.stop()
    }
}
