import ChatKit
import Testing
@testable import DesignSystem

@MainActor
struct AudioCallHeaderTests {
    private let id = Conversation.ID("conversation")

    private func header(
        kind: Conversation.Kind = .directMessage,
        supported: Bool = true,
        hasAction: Bool = true,
        selected: Bool = true,
        mentions: Bool = false,
        threads: Bool = false
    ) -> ChatWindow {
        ChatWindow(
            state: ChatSceneState(
                conversations: [Conversation(id: id, kind: kind)],
                selected: selected ? id : nil,
                showingMentions: mentions,
                threads: ThreadSceneState(showingList: threads),
                callableConversations: supported ? [id] : []
            ),
            actions: ChatSceneActions(call: hasAction ? { _ in } : nil)
        )
    }

    @Test func callIsOfferedForTheSupportedSelectedDM() {
        #expect(header().callConversation == id)
        #expect(header(supported: false).callConversation == nil)
        #expect(header(hasAction: false).callConversation == nil)
        #expect(header(selected: false).callConversation == nil)
    }

    @Test(arguments: [
        Conversation.Kind.appDirectMessage, .groupDirectMessage, .space, .meetChat, .unknown("future")
    ])
    func otherConversationKindsHaveNoCallButton(_ kind: Conversation.Kind) {
        #expect(header(kind: kind).callConversation == nil)
    }

    @Test func listsHaveNoCallButtonEvenWithAStaleSelection() {
        #expect(header(mentions: true).callConversation == nil)
        #expect(header(threads: true).callConversation == nil)
    }
}
