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
        #expect(DateChoice.week.bound(now: now) == now.addingTimeInterval(-7 * 86400))
        #expect(DateChoice.day.bound(now: now) == now.addingTimeInterval(-86400))
        #expect(DateChoice.year.bound(now: now) == now.addingTimeInterval(-365 * 86400))
        #expect(DateChoice.any.bound(now: now) == nil)
    }

    /// Each Date chip offers its own choices, named in title case.
    @Test func eachDateChipNamesItsOwnChoices() {
        #expect(DateChoice.older.map(\.olderTitle) == [
            "Any Time", "Older Than a Week", "Older Than a Month", "Older Than a Year"
        ])
        #expect(DateChoice.newer.map(\.newerTitle) == [
            "Any Time", "Past Day", "Past Week", "Past Month", "Past Year"
        ])
    }

    /// The menu checks the choice that made the query's instant, without
    /// reading the clock: Any Time with no bound, the remembered choice for
    /// its own bound, and nothing for a bound it did not make.
    @Test func aDateChipChecksTheChoiceThatMadeItsBound() {
        let bound = Date(timeIntervalSince1970: 1_790_000_000)
        let pick = DatePick(choice: .month, bound: bound)
        #expect(DatePick.checked(nil, remembered: pick) == .any)
        #expect(DatePick.checked(nil, remembered: nil) == .any)
        #expect(DatePick.checked(bound, remembered: pick) == .month)
        #expect(DatePick.checked(bound.addingTimeInterval(1), remembered: pick) == nil)
        #expect(DatePick.checked(bound, remembered: nil) == nil)
    }

    @Test func theHasChipChecksOneChoice() {
        #expect(HasChoice.of(MessageSearchQuery()) == .anything)
        #expect(HasChoice.of(MessageSearchQuery(hasFile: true)) == .file)
        #expect(HasChoice.of(MessageSearchQuery(hasLink: true)) == .link)
        #expect(HasChoice.of(MessageSearchQuery(hasFile: true, hasLink: true)) == nil)
    }

    // MARK: Selection: Spotlight-like — the top result, unless a row is picked

    static let rows: [SearchRow] = [
        .conversation(Conversation.ID("c")), .person(Member.ID("p")), .message(Message.ID("1"))
    ]

    @Test func typingSelectsTheTopRow() {
        // No explicit pick: the rows that answer the new text select their
        // own top row, the way Spotlight does.
        #expect(SearchRows.selected(previous: nil, explicit: false, in: Self.rows) == Self.rows[0])
        #expect(SearchRows.selected(previous: .person(Member.ID("p")), explicit: false, in: Self.rows) == Self
            .rows[0])
        #expect(SearchRows.selected(previous: nil, explicit: false, in: []) == nil)
    }

    @Test func anArrowPickSurvivesARowsUpdateWhileItIsStillListed() {
        #expect(SearchRows.selected(previous: Self.rows[1], explicit: true, in: Self.rows) == Self.rows[1])
    }

    @Test func anArrowPickIsDroppedOnceItsRowIsGone() {
        // Falls back to the new top row, not to nothing.
        #expect(SearchRows
            .selected(previous: .person(Member.ID("gone")), explicit: true, in: Self.rows) == Self.rows[0])
    }

    @Test func aKeystrokeDropsThePickBackToTheTopRow() {
        // `explicit: false` is what a keystroke leaves behind (SearchOverlay
        // clears its own `explicitPick` flag on every text change), even
        // though a row is still otherwise listed.
        #expect(SearchRows.selected(previous: Self.rows[1], explicit: false, in: Self.rows) == Self.rows[0])
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

    @Test func returnOpensTheSelectedRow() {
        #expect(SearchRows.returnAction(selected: Self.rows[1], rows: Self.rows) == .open(Self.rows[1]))
    }

    @Test func returnWithNoSelectionOpensTheTopRow() {
        // Defensive: the overlay always keeps a row selected when any are
        // listed, but `returnAction` does not depend on that.
        #expect(SearchRows.returnAction(selected: nil, rows: Self.rows) == .open(Self.rows[0]))
    }

    @Test func returnWithNoRowsSubmits() {
        #expect(SearchRows.returnAction(selected: nil, rows: []) == .submit)
        #expect(SearchRows.returnAction(selected: Self.rows[0], rows: []) == .submit)
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

    @Test func thePanelIsAtMost760Wide() {
        #expect(SearchOverlayLayout.panelWidth(for: 1100) == 760)
    }

    /// Every chip and the sort menu fit the widest panel without scrolling,
    /// measured hosted (CLAUDE.md: `NSHostingView` runs headless), and with
    /// room to spare for a chip that names its choice.
    @Test func theWidestPanelHoldsEveryFilterAndTheSortMenu() {
        let filters: Set<MessageSearchFilter> = [
            .from, .conversation, .olderThan, .newerThan, .hasFile, .hasLink, .mentionsMe, .newestFirst
        ]
        for order in [MessageSearchOrder.relevance, .newest] {
            var query = MessageSearchQuery(text: "plan")
            query.order = order
            let row = SearchFilterRow(
                query: query, filters: filters, people: [], conversations: [], directory: [:], me: nil,
                setQuery: { _ in }
            )
            let needed = NSHostingView(rootView: row.fixedSize()).fittingSize.width
            #expect(needed > 600)
            #expect(needed + 60 <= SearchOverlayLayout.maximumWidth)
        }
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
