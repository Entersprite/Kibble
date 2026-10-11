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

    // MARK: Selection: nothing until a row is picked, so Return searches

    static let rows: [SearchRow] = [
        .conversation(Conversation.ID("c")), .person(Member.ID("p")), .message(Message.ID("1"))
    ]

    @Test func typingLeavesNothingSelected() {
        // The overlay clears the pick on a text change; the rows that answer
        // the new text keep it cleared.
        #expect(SearchRows.kept(nil, in: Self.rows) == nil)
        #expect(SearchRows.initialSelection(SearchSceneState(
            query: MessageSearchQuery(text: "de"),
            hits: [Self.message("1")]
        )) == nil)
    }

    @Test func downFromNothingSelectsTheFirstRow() {
        #expect(SearchRows.next(after: Self.rows, selected: nil, by: 1) == Self.rows[0])
    }

    @Test func upAndDownStopAtTheEnds() {
        #expect(SearchRows.next(after: Self.rows, selected: Self.rows[2], by: 1) == Self.rows[2])
        #expect(SearchRows.next(after: Self.rows, selected: Self.rows[0], by: -1) == Self.rows[0])
        #expect(SearchRows.next(after: Self.rows, selected: Self.rows[0], by: 1) == Self.rows[1])
        #expect(SearchRows.next(after: [], selected: nil, by: 1) == nil)
    }

    @Test func aPickStaysWhileItsRowIsListed() {
        #expect(SearchRows.kept(Self.rows[1], in: Self.rows) == Self.rows[1])
        #expect(SearchRows.kept(.person(Member.ID("gone")), in: Self.rows) == nil)
    }

    @Test func aListedFocusIsSelectedOnOpen() {
        var search = SearchSceneState(
            query: MessageSearchQuery(text: "deploy"),
            hits: [Self.message("1"), Self.message("2")],
            focus: Message.ID("2")
        )
        #expect(SearchRows.initialSelection(search) == .message(Message.ID("2")))
        search.focus = Message.ID("absent")
        #expect(SearchRows.initialSelection(search) == nil)
    }

    @Test func messagesAreSearchedFromTwoCharactersOrAFilter() {
        #expect(!SearchRows.searchesMessages(MessageSearchQuery(text: "d")))
        #expect(SearchRows.searchesMessages(MessageSearchQuery(text: "de")))
        #expect(SearchRows.searchesMessages(MessageSearchQuery(text: "", mentionsMe: true)))
    }

    /// Search fix wave, finding 1: the field follows a query text set without
    /// typing (a person row clears it), and never re-sends what it sent.
    @Test func theFieldAdoptsTextItDidNotSend() {
        #expect(SearchRows.adopted("", sent: "alex") == "")
        #expect(SearchRows.adopted("deploy", sent: "something else") == "deploy")
        #expect(SearchRows.adopted("alex", sent: "alex") == nil)
    }

    /// Search fix wave, findings 6 and 7: a spinner while a page is out, a
    /// retry after a failed one, else the trigger while there is more.
    @Test func theMoreRowFollowsThePage() {
        #expect(SearchRows.more(SearchSceneState(isLoadingMore: true, hasMore: true)) == .loading)
        #expect(SearchRows.more(SearchSceneState(loadMoreFailed: true, hasMore: true)) == .retry)
        #expect(SearchRows.more(SearchSceneState(hasMore: true)) == .trigger)
        #expect(SearchRows.more(SearchSceneState()) == nil)
    }

    // MARK: Layout

    @Test func thePanelIsAtMost680Wide() {
        #expect(SearchOverlayLayout.panelWidth(for: 1100) == 680)
    }

    @Test func aNarrowWindowKeeps40PointsEachSide() {
        #expect(SearchOverlayLayout.panelWidth(for: 600) == 520)
        #expect(SearchOverlayLayout.panelWidth(for: 50) == 0)
    }

    /// The panel is laid out headless (CLAUDE.md: `NSHostingView` runs headless);
    /// its look is checked on the owner's screen, not here.
    @Test func theOverlayLaysOutHosted() {
        var state = ChatSceneState()
        state.capabilities = Capabilities(canSearchMessages: true, messageSearchFilters: [.from, .hasLink])
        state.search = SearchSceneState(
            isShown: true,
            query: MessageSearchQuery(text: "deploy"),
            hits: (1 ... 8).map { Self.message(String($0)) }
        )
        let host = NSHostingView(rootView: SearchOverlay(state: state, actions: .inert))
        host.frame = NSRect(x: 0, y: 0, width: 1100, height: 760)
        host.layout()
        #expect(host.fittingSize.width > 0)
        #expect(host.fittingSize.height > 0)
    }
}

extension SearchActions {
    @MainActor static let inert = SearchActions(
        show: {}, hide: {}, textChanged: { _ in }, setQuery: { _ in }, submit: {}, loadMore: {},
        openConversation: { _ in }, openPerson: { _ in }, openMessage: { _ in }, step: { _ in }, end: {}
    )
}
