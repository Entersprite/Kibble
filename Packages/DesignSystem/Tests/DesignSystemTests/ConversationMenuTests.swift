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
    }
}
