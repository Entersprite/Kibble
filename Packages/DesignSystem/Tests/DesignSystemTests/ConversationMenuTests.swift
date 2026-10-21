import ChatKit
import Foundation
import Testing
@testable import DesignSystem

/// The sidebar row menu's gating - the final review's m2. The view used to
/// decide this inline, where deleting the receipts check failed nothing.
struct ConversationMenuTests {
    private typealias Offers = ConversationMenu.Offers

    private let id = Conversation.ID("dm/1")
    private let all = Offers(markRead: true, mute: true, unmute: true, notificationSettings: true)

    private func items(
        unread: Bool = true,
        muted: Bool = false,
        dimmed: Bool = false,
        receiptsWithheld: Bool = false,
        offers: Offers? = nil
    ) -> [ConversationMenu.Item] {
        let state = ChatSceneState(
            dimmed: dimmed ? [id] : [],
            muted: muted ? [id] : [],
            receiptsWithheld: receiptsWithheld ? [id] : []
        )
        return ConversationMenu.items(
            for: Conversation(id: id, kind: .directMessage, hasUnread: unread),
            state: state,
            offers: offers ?? all
        )
    }

    @Test func everythingOfferedOnAnUnreadRowInOrder() {
        #expect(items() == [.markAsRead, .mute, .notificationSettings])
    }

    @Test func markAsReadNeedsAnUnreadRow() {
        #expect(items(unread: false) == [.mute, .notificationSettings])
    }

    /// Decision 7: it would be refused at `SyncEngine.submit`, so it is hidden.
    @Test func markAsReadIsHiddenWhereReceiptsAreWithheld() {
        #expect(items(receiptsWithheld: true) == [.mute, .notificationSettings])
    }

    @Test func markAsReadNeedsTheHostsAction() {
        let offers = Offers(mute: true, unmute: true, notificationSettings: true)
        #expect(items(offers: offers) == [.mute, .notificationSettings])
    }

    @Test func aMutedRowOffersUnmuteInsteadOfMute() {
        #expect(items(muted: true) == [.markAsRead, .unmute, .notificationSettings])
    }

    /// Decision 1: dimmed by its section or the Meet preset is not the
    /// conversation's own record, so there is nothing of its own to unmute.
    @Test func aRowDimmedButNotMutedStillOffersMute() {
        #expect(items(dimmed: true) == [.markAsRead, .mute, .notificationSettings])
    }

    @Test func eachItemOnlyWhereItsActionWasOffered() {
        #expect(items(offers: Offers()) == [])
        #expect(items(muted: true, offers: Offers(mute: true)) == [])
        #expect(items(offers: Offers(unmute: true)) == [])
        #expect(items(offers: Offers(notificationSettings: true)) == [.notificationSettings])
    }

    @MainActor
    @Test func theOffersAreWhicheverClosuresTheHostSupplied() {
        #expect(Offers(ChatSceneActions()) == Offers())
        #expect(Offers(ChatSceneActions(mute: { _ in })) == Offers(mute: true))
        #expect(Offers(ChatSceneActions(unmute: { _ in })) == Offers(unmute: true))
        #expect(Offers(ChatSceneActions(markRead: { _ in })) == Offers(markRead: true))
        let settings = ChatSceneActions(showNotificationSettings: { _ in })
        #expect(Offers(settings) == Offers(notificationSettings: true))
        #expect(Offers(ChatSceneActions(call: { _ in })) == Offers(call: true))
    }

    @Test func callLeadsTheMenuOfADMTheHeaderWouldCall() {
        var offers = all
        offers.call = true
        let callable = ChatSceneState(callableConversations: [id])
        let dm = Conversation(id: id, kind: .directMessage, hasUnread: true)
        #expect(ConversationMenu.items(for: dm, state: callable, offers: offers)
            == [.call, .markAsRead, .mute, .notificationSettings])
        // Ahead of Mark as Unread too, which otherwise goes first.
        offers.conversationActions = Capabilities(canMarkUnread: true)
        let first = Array(ConversationMenu.items(for: dm, state: callable, offers: offers).prefix(2))
        #expect(first == [.call, .action(.markUnread)])
        // Not for a DM calls cannot reach, nor without the host's action.
        #expect(!ConversationMenu.items(for: dm, state: ChatSceneState(), offers: offers).contains(.call))
        #expect(!ConversationMenu.items(for: dm, state: callable, offers: all).contains(.call))
        for kind in [Conversation.Kind.groupDirectMessage, .appDirectMessage, .space, .meetChat] {
            let other = Conversation(id: id, kind: kind)
            #expect(!ConversationMenu.items(for: other, state: callable, offers: offers).contains(.call))
        }
    }

    private func meeting(_ id: String, start: Double, unread: Bool = false) -> Conversation {
        Conversation(
            id: .init(id), kind: .meetChat, title: "Planning", hasUnread: unread,
            meeting: MeetingOccurrence(
                seriesID: .init("parent-\(id)"), occurrenceID: id, seriesTitle: "Planning",
                scheduledStart: Date(timeIntervalSince1970: start)
            )
        )
    }

    private func entries(_ conversations: [Conversation], state: ChatSceneState = .init()) throws
        -> [ConversationMenu.Entry] {
        let series = try #require(MeetingSeries.build(conversations).first)
        return ConversationMenu.entries(for: series, state: state, offers: all)
    }

    @Test func aSeriesWithOneOccurrenceOffersThatChatsOwnMenu() throws {
        let only = meeting("only", start: 100, unread: true)
        #expect(try entries([only]) == [
            .init(item: .markAsRead, targets: [only.id]),
            .init(item: .mute, targets: [only.id]),
            .init(item: .notificationSettings, targets: [only.id])
        ])
    }

    @Test func aSeriesReadsEachUnreadOriginalAndMutesAllOfThem() throws {
        let old = meeting("old", start: 100, unread: true)
        let withheld = meeting("withheld", start: 200, unread: true)
        let read = meeting("read", start: 300)
        let latest = meeting("latest", start: 400, unread: true)
        let state = ChatSceneState(muted: [read.id], receiptsWithheld: [withheld.id])
        #expect(try entries([old, withheld, read, latest], state: state) == [
            .init(item: .markAsRead, targets: [old.id, latest.id]),
            .init(item: .mute, targets: [old.id, withheld.id, latest.id])
        ])
    }

    @Test func aFullyMutedSeriesUnmutesEveryOriginal() throws {
        let old = meeting("old", start: 100)
        let latest = meeting("latest", start: 200)
        let state = ChatSceneState(muted: [old.id, latest.id])
        #expect(try entries([old, latest], state: state) == [
            .init(item: .unmute, targets: [old.id, latest.id])
        ])
    }

    // MARK: The list's one menu, resolved for the clicked row

    private let ada = Member(id: Member.ID("users/ada"), kind: .human, displayName: "Ada Lovelace")
    private let me = Member.ID("users/me")

    private func sidebar(_ conversations: [Conversation], state: ChatSceneState) -> [SidebarSection] {
        SidebarProjection.build(
            conversations,
            preferences: state.sidebarPreferences,
            directory: state.directory
        )
    }

    /// The clicked row's own items, its favorite, and the name a
    /// confirmation asks about, as the per-row menu had them.
    @Test func aRightClickedConversationGetsItsOwnMenu() {
        let dm = Conversation(id: id, kind: .directMessage, hasUnread: true, members: [me, ada.id])
        let state = ChatSceneState(conversations: [dm], directory: [ada.id: ada], me: me, muted: [id])
        let menu = ConversationMenu.rowMenu(
            for: [.conversation(id)], in: sidebar([dm], state: state), state: state, offers: all
        )
        #expect(menu == ConversationMenu.RowMenu(
            entries: [.markAsRead, .unmute, .notificationSettings].map { .init(item: $0, targets: [id]) },
            favorite: .conversation(id),
            title: "Ada Lovelace"
        ))
    }

    @Test func aRightClickedMeetingSeriesActsOnItsOriginals() throws {
        let old = meeting("old", start: 100, unread: true)
        let latest = meeting("latest", start: 200, unread: true)
        let state = ChatSceneState(conversations: [old, latest])
        let series = try #require(MeetingSeries.build([old, latest]).first)
        let menu = try #require(ConversationMenu.rowMenu(
            for: [.meetingSeries(series.id)], in: sidebar([old, latest], state: state), state: state,
            offers: all
        ))
        #expect(menu.entries == ConversationMenu.entries(for: series, state: state, offers: all))
        #expect(menu.favorite == .meetingSeries(series.id))
        #expect(menu.title == "Planning")
    }

    /// Empty space, a pinned row, several rows, or a row the sections no
    /// longer hold: no menu at all, rather than one for the wrong thing.
    @Test func onlyOneRowTheListDrewHasAMenu() {
        let dm = Conversation(id: id, kind: .directMessage, members: [me, ada.id])
        let space = Conversation(id: .init("space/1"), kind: .space, title: "Deploys")
        let state = ChatSceneState(conversations: [dm, space], directory: [ada.id: ada], me: me)
        let sections = sidebar([dm, space], state: state)
        func menu(_ clicked: Set<SidebarSelection>) -> ConversationMenu.RowMenu? {
            ConversationMenu.rowMenu(for: clicked, in: sections, state: state, offers: all)
        }
        #expect(menu([]) == nil)
        #expect(menu([.mentions]) == nil)
        #expect(menu([.conversation(id), .conversation(space.id)]) == nil)
        #expect(menu([.conversation(.init("gone"))]) == nil)
        #expect(menu([.conversation(space.id)])?.title == "Deploys")
    }
}
