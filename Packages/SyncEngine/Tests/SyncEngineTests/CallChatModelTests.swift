import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import SyncEngine

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct CallChatModelTests {
    @Test func callChatObservesAndSendsToItsOwnConversationWithoutChangingSelection() async throws {
        let backend = RecordingBackend()
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let model = ChatSessionModel(store: store, engine: engine, me: FixtureWorld.minimal.me)
        try await model.start()
        model.setActive(false)
        await settleAutoMarkRead(until: "world") { !model.conversations.isEmpty }
        let selected = Conversation.ID("dm:1"), call = Conversation.ID("space:1")
        model.select(selected)
        model.openCallChat(in: call)
        await settleAutoMarkRead(until: "call messages") { !model.callChat.messages.isEmpty }
        #expect(model.callChat.messages.allSatisfy { $0.conversationID == call })
        model.updateCallChatDraft("From the call", in: call)
        model.closeCallChat(in: call)
        model.openCallChat(in: call)
        #expect(model.callChat.draft == "From the call")
        model.sendCallChat(in: call)
        await settleAutoMarkRead(until: "call send") { !model.callChat.isSending }
        let commands = await backend.commands
        #expect(commands.contains {
            if case let .sendMessage(conversation, _, text, _, _, _, _) = $0 {
                return conversation == call && text == "From the call"
            }
            return false
        })
        #expect(model.selected == selected)
        #expect(model.callChat.draft.isEmpty)
        await model.stop()
        #expect(model.callChat.conversationID == nil)
        #expect(model.callChat.messages.isEmpty)
    }

    @Test func draftsStayWithTheirOwnConversationAndDisappearOnAccountTeardown() async throws {
        let backend = FakeBackend(world: .minimal)
        let store = try ChatStore.inMemory()
        let model = ChatSessionModel(store: store, engine: SyncEngine(backend: backend, store: store))
        let first = Conversation.ID("dm:1"), second = Conversation.ID("space:1")
        model.openCallChat(in: first)
        model.updateCallChatDraft("First draft", in: first)
        model.openCallChat(in: second)
        model.updateCallChatDraft("Second draft", in: second)
        model.openCallChat(in: first)
        #expect(model.callChat.draft == "First draft")
        model.updateCallChatDraft("Stale callback", in: second)
        #expect(model.callChat.draft == "First draft")
        await model.stop()
        #expect(model.callChat.draft.isEmpty)
        #expect(model.callChat.savedDrafts.isEmpty)
    }
}
