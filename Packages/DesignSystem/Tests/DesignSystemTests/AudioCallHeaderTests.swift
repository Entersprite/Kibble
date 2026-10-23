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
        hasVideo: Bool = true,
        selected: Bool = true,
        mentions: Bool = false,
        threads: Bool = false
    ) -> ChatWindow {
        var actions = ChatSceneActions(call: hasAction ? { _ in } : nil)
        actions.videoCall = hasVideo ? { _ in } : nil
        return ChatWindow(
            state: ChatSceneState(
                conversations: [Conversation(id: id, kind: kind)],
                selected: selected ? id : nil,
                showingMentions: mentions,
                threads: ThreadSceneState(showingList: threads),
                callableConversations: supported ? [id] : []
            ),
            actions: actions
        )
    }

    @Test func callIsOfferedForTheSupportedSelectedDM() {
        #expect(header().callConversation == id)
        #expect(header(supported: false).callConversation == nil)
        #expect(header(hasAction: false).callConversation == nil)
        #expect(header(selected: false).callConversation == nil)
    }

    @Test func videoCallSitsBesideCallOnlyForAHostWithVideo() {
        #expect(header().videoCallConversation == id)
        #expect(header(hasVideo: false).videoCallConversation == nil)
        #expect(header(hasVideo: false).callConversation == id)
        // Never a camera without the call it starts.
        #expect(header(hasAction: false).videoCallConversation == nil)
        #expect(header(supported: false).videoCallConversation == nil)
        #expect(header(selected: false).videoCallConversation == nil)
    }

    /// The call service names what it can call, groups and spaces included;
    /// the header draws Call for exactly those.
    @Test(arguments: [
        Conversation.Kind.appDirectMessage, .groupDirectMessage, .space, .meetChat, .unknown("future")
    ])
    func anyKindHasCallOnlyWhereTheServiceCanCallIt(_ kind: Conversation.Kind) {
        #expect(header(kind: kind).callConversation == id)
        #expect(header(kind: kind, supported: false).callConversation == nil)
        #expect(header(kind: kind, supported: false).videoCallConversation == nil)
    }

    @Test(arguments: [
        (Conversation.Kind.directMessage, false), (.groupDirectMessage, true), (.appDirectMessage, true),
        (.space, true)
    ])
    func detailsAreOfferedForEverythingButAOneToOneDM(_ kind: Conversation.Kind, _ offered: Bool) {
        var capabilities = Capabilities()
        capabilities.canReadConversationDetails = true
        var actions = ChatSceneActions(call: { _ in })
        actions.browser = ConversationBrowserActions(
            show: { _ in }, back: {}, search: { _, _, _ in }, reviewCreation: {}, searchPeople: { _ in },
            beginCreation: { _ in }, create: { _ in }, closePanel: {}, details: { _, _ in },
            preview: { _ in }, mutate: { _ in }
        )
        let window = ChatWindow(
            state: ChatSceneState(
                conversations: [Conversation(id: id, kind: kind)], selected: id,
                capabilities: capabilities, callableConversations: [id]
            ),
            actions: actions
        )
        #expect(window.showsDetailsButton == offered)
    }

    @Test func listsHaveNoCallButtonEvenWithAStaleSelection() {
        #expect(header(mentions: true).callConversation == nil)
        #expect(header(threads: true).callConversation == nil)
        #expect(header(mentions: true).videoCallConversation == nil)
        #expect(header(threads: true).videoCallConversation == nil)
    }
}
