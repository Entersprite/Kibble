import ChatKit
import Foundation
import Testing
@testable import DesignSystem

/// Opening a mention scrolls the transcript to it once. After that, arrivals
/// scroll to the newest as before (ruling 14).
struct TranscriptScrollTests {
    private func message(_ id: String) -> Message {
        Message(
            id: Message.ID(id), conversationID: Conversation.ID("space:1"), threadID: MessageThread.ID("t"),
            sender: Member.ID("users/alice"), text: id, createdAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
    }

    private var messages: [Message] {
        [message("m:1"), message("m:2"), message("m:3")]
    }

    @Test func aLoadedTargetNotYetHonouredIsScrolledTo() {
        #expect(TranscriptScroll.destination(messages: messages, target: Message.ID("m:1"), honoured: nil)
            == .message(Message.ID("m:1")))
    }

    @Test func anHonouredTargetGivesWayToTheNewest() {
        #expect(TranscriptScroll.destination(
            messages: messages, target: Message.ID("m:1"),
            honoured: TranscriptScroll.Request(id: Message.ID("m:1"))
        ) == .newest(Message.ID("m:3")))
    }

    @Test func aTargetNotLoadedYetShowsTheNewestUntilItArrives() {
        #expect(TranscriptScroll.destination(messages: messages, target: Message.ID("m:9"), honoured: nil)
            == .newest(Message.ID("m:3")))
    }

    @Test func noTargetIsTheNewestAndNoMessagesIsNothing() {
        #expect(TranscriptScroll.destination(messages: messages, target: nil, honoured: nil)
            == .newest(Message.ID("m:3")))
        #expect(TranscriptScroll.destination(messages: [], target: Message.ID("m:1"), honoured: nil) == nil)
    }

    /// Search fix wave, finding 3: the same hit opened again is a newer
    /// request, so it is scrolled to again; the same open is honoured once.
    @Test func theSameTargetOpenedAgainIsScrolledToAgain() {
        let honoured = TranscriptScroll.Request(id: Message.ID("m:1"), generation: 1)
        #expect(TranscriptScroll.destination(
            messages: messages, target: Message.ID("m:1"), generation: 2, honoured: honoured
        ) == .message(Message.ID("m:1")))
        #expect(TranscriptScroll.destination(
            messages: messages, target: Message.ID("m:1"), generation: 1, honoured: honoured
        ) == .newest(Message.ID("m:3")))
    }

    /// Only the generation moves when the same hit opens again, so it alone
    /// must fire the scroll and the mark.
    @Test func aNewOpenOfTheSameTargetChangesBothTriggers() {
        var state = ChatSceneState(
            messages: messages, scrollTarget: Message.ID("m:1"), highlightedMessage: Message.ID("m:1"),
            searchOpenGeneration: 1
        )
        let scroll = TranscriptScroll.Trigger(state)
        let mark = TranscriptMarkTrigger(state)
        state.searchOpenGeneration = 2
        #expect(TranscriptScroll.Trigger(state) != scroll)
        #expect(TranscriptMarkTrigger(state) != mark)
    }

    /// The trigger must change when a target is set on messages already
    /// loaded, or the scroll would wait for the next arrival.
    @Test func theTriggerChangesWhenATargetIsSetOnLoadedMessages() {
        var state = ChatSceneState(messages: messages)
        let before = TranscriptScroll.Trigger(state)
        state.scrollTarget = Message.ID("m:1")
        #expect(TranscriptScroll.Trigger(state) != before)
        // Moving the target between two loaded messages leaves `newest` and
        // `targetLoaded` as they were, so only `target` can fire this.
        let onFirst = TranscriptScroll.Trigger(state)
        state.scrollTarget = Message.ID("m:2")
        #expect(TranscriptScroll.Trigger(state) != onFirst)
    }

    /// A target that loads without becoming the newest (an older page
    /// arriving) leaves `newest` and `target` as they were, so only
    /// `targetLoaded` can fire the scroll.
    @Test func theTriggerChangesWhenAnOlderTargetLoads() {
        var state = ChatSceneState(
            messages: [message("m:2"), message("m:3")], scrollTarget: Message.ID("m:1")
        )
        let before = TranscriptScroll.Trigger(state)
        state.messages.insert(message("m:1"), at: 0)
        #expect(TranscriptScroll.Trigger(state) != before)
    }

    @Test func arrivalsAndAnHonouredSearchDoNotPullSomeoneAwayFromReading() {
        #expect(TranscriptScroll.destination(
            messages: messages, target: nil, honoured: nil, followNewest: false
        ) == nil)
        #expect(TranscriptScroll.destination(
            messages: messages, target: Message.ID("m:1"),
            honoured: TranscriptScroll.Request(id: Message.ID("m:1")), followNewest: false
        ) == nil)
        #expect(TranscriptScroll.destination(
            messages: messages, target: Message.ID("m:1"), honoured: nil, followNewest: false
        ) == .message(Message.ID("m:1")))
    }

    @MainActor
    @Test func onlyUserVisibilityMovementTowardAnEdgePages() {
        let rows = (0 ..< 30).map { message("m:\($0)") }
        let paging = TranscriptPaging()
        func visible(_ range: Range<Int>) -> [Message.ID] {
            range.map { rows[$0].id }
        }
        #expect(paging.update(visibleIDs: visible(5 ..< 8), messages: rows) == nil)
        #expect(paging.update(visibleIDs: visible(3 ..< 6), messages: rows) == nil)
        paging.hasUserIntent = true
        #expect(paging.update(visibleIDs: visible(2 ..< 5), messages: rows) == .older)
        #expect(paging.update(visibleIDs: visible(2 ..< 5), messages: rows) == nil)
        #expect(paging.update(visibleIDs: visible(3 ..< 6), messages: rows) == nil)
        #expect(paging.update(visibleIDs: visible(25 ..< 28), messages: rows) == .newer)
        paging.hasUserIntent = false
        #expect(paging.update(visibleIDs: visible(0 ..< 3), messages: rows) == nil)
    }

    @Test func theBottomOfATallRowMustBeVisibleBeforeArrivalsFollow() {
        #expect(!TranscriptEndTracking.isNearBottom(
            rowHeight: 2000, viewport: CGRect(x: 0, y: 0, width: 600, height: 500)
        ))
        #expect(TranscriptEndTracking.isNearBottom(
            rowHeight: 2000, viewport: CGRect(x: 0, y: 1500, width: 600, height: 500)
        ))
        #expect(!TranscriptEndTracking.isNearBottom(
            rowHeight: 100, viewport: CGRect(x: 0, y: 200, width: 600, height: 500)
        ))
        #expect(!TranscriptEndTracking.isNearBottom(rowHeight: 100, viewport: nil))
    }

    @Test func completingALatestJumpChangesTheTriggerEvenWhenNewestAndTargetStayTheSame() {
        var state = ChatSceneState(
            messages: messages, hasNewerMessages: true, newerMessagesAreLatestJump: true,
            isLoadingNewerMessages: true
        )
        let before = TranscriptScroll.Trigger(state)
        state.isLoadingNewerMessages = false
        #expect(TranscriptScroll.Trigger(state) != before)
        let afterLoading = TranscriptScroll.Trigger(state)
        state.newerMessagesAreLatestJump = false
        #expect(TranscriptScroll.Trigger(state) != afterLoading)
    }
}
