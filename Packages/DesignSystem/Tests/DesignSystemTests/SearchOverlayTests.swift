import AppKit
import ChatKit
import SwiftUI
import Testing
@testable import DesignSystem

@MainActor
struct SearchOverlayTests {
    static let me = Member.ID("me")
    static func message(_ id: String) -> Message {
        Message(
            id: Message.ID(id), conversationID: Conversation.ID("c"), threadID: MessageThread.ID(id),
            sender: me, text: "deploy \(id)", createdAt: Date(timeIntervalSince1970: 1_791_000_000)
        )
    }

    @Test func anEmptyQueryListsRecents() {
        let rows = SearchRows.rows(SearchSceneState(recents: ["deploy", "invoice"]))
        #expect(rows == [.recent("deploy"), .recent("invoice")])
    }

    @Test func sectionsComeInOrder() {
        let search = SearchSceneState(
            query: MessageSearchQuery(text: "de"),
            conversations: [Conversation(id: Conversation.ID("c"), kind: .space, title: "Deploys")],
            people: [Member(id: Member.ID("p"), kind: .human, displayName: "Dee")],
            hits: [Self.message("1")]
        )
        #expect(SearchRows.rows(search) == [
            .conversation(Conversation.ID("c")),
            .person(Member.ID("p")),
            .message(Message.ID("1"))
        ])
    }

    @Test func dateChoicesCountBackFromNow() {
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        #expect(DateChoice.olderThanAWeek.bound(now: now) == now.addingTimeInterval(-7 * 86400))
        #expect(DateChoice.any.bound(now: now) == nil)
    }

    /// The panel is laid out headless (CLAUDE.md: `NSHostingView` runs headless);
    /// its look is checked on the owner's screen, not here.
    @Test func thePanelFitsItsWidth() {
        var state = ChatSceneState()
        state.capabilities = Capabilities(canSearchMessages: true, messageSearchFilters: [.from, .hasLink])
        state.search = SearchSceneState(
            isShown: true,
            query: MessageSearchQuery(text: "deploy"),
            hits: (1 ... 8).map { Self.message(String($0)) }
        )
        let host = NSHostingView(rootView: SearchOverlay(state: state, actions: .inert).frame(
            width: 1100,
            height: 760
        ))
        host.layout()
        #expect(host.fittingSize.width <= 1100)
    }
}

extension SearchActions {
    @MainActor static let inert = SearchActions(
        show: {}, hide: {}, textChanged: { _ in }, setQuery: { _ in }, submit: {}, loadMore: {},
        openConversation: { _ in }, openPerson: { _ in }, openMessage: { _ in }, step: { _ in }, end: {}
    )
}
