import ChatKit
import Foundation
import Testing
@testable import DesignSystem

struct SearchResultsBarTests {
    static let query = MessageSearchQuery(text: "deploy")

    @Test func thePositionCountsLoadedHits() {
        #expect(SearchBarText.position(SearchBarScene(query: Self.query, index: 8, count: 16)) == "9 of 16")
        #expect(SearchBarText.position(SearchBarScene(query: Self.query, index: 0, count: 20, hasMore: true))
            == "1 of 20+")
    }

    @Test func openingReplacesThePosition() {
        #expect(SearchBarText.position(SearchBarScene(query: Self.query, index: 0, count: 3, isOpening: true))
            == "Loading older messages…")
    }

    /// Search fix wave, finding 5: why a hit cannot open, beside where it is.
    @Test func unreachableSaysWhyBesideThePosition() {
        #expect(SearchBarText.position(SearchBarScene(
            query: Self.query, index: 0, count: 3, unreachable: .tooFarBack
        )) == "1 of 3 · Couldn't open this message")
        #expect(SearchBarText.position(SearchBarScene(
            query: Self.query, index: 1, count: 3, hasMore: true, unreachable: .notInSidebar
        )) == "2 of 3+ · Can't open this message here")
    }

    /// A page that failed to load past the last loaded hit says so beside
    /// the position, the same way an unreachable hit does.
    @Test func aFailedPageSaysSoBesideThePosition() {
        #expect(SearchBarText.position(SearchBarScene(
            query: Self.query, index: 0, count: 3, hasMore: true, pageFailed: true
        )) == "1 of 3+ · Couldn't load more results")
    }

    @Test func aMessageIsMarkedOnceWhenItIsThere() {
        let message = Message(
            id: Message.ID("m"), conversationID: Conversation.ID("c"), threadID: MessageThread.ID("m"),
            sender: Member.ID("s"), text: "x", createdAt: .now
        )
        let first = TranscriptScroll.Request(id: message.id, generation: 1)
        #expect(TranscriptMark.shouldMark(first, in: [message], marked: nil))
        #expect(!TranscriptMark.shouldMark(first, in: [message], marked: first))
        #expect(!TranscriptMark.shouldMark(first, in: [], marked: nil))
        #expect(!TranscriptMark.shouldMark(nil, in: [message], marked: nil))
        // Search fix wave, finding 3: the same message opened again is marked again.
        let again = TranscriptScroll.Request(id: message.id, generation: 2)
        #expect(TranscriptMark.shouldMark(again, in: [message], marked: first))
    }

    @Test func theMarkTurnsOnBeforeItsWait() async {
        var onCalled = false
        await TranscriptMark.fade(on: { onCalled = true }, sleep: {}, isStillMarked: { true }, off: {})
        #expect(onCalled)
    }

    @Test func anUndisturbedMarkTurnsOffAfterItsWait() async {
        var offCalled = false
        await TranscriptMark.fade(on: {}, sleep: {}, isStillMarked: { true }, off: { offCalled = true })
        #expect(offCalled)
    }

    /// `try?` around the sleep once swallowed
    /// `CancellationError`, so a mark a newer trigger had already canceled
    /// still ran `off()` - which could switch the newer mark back off.
    @Test func aCanceledWaitNeverTurnsTheMarkOff() async {
        struct Canceled: Error {}
        var offCalled = false
        await TranscriptMark.fade(
            on: {},
            sleep: { throw Canceled() },
            isStillMarked: { true },
            off: { offCalled = true }
        )
        #expect(!offCalled)
    }

    /// A mark superseded between the wait ending and the check (or a stale
    /// `isStillMarked` for any other reason) also never turns off - only the
    /// mark that is still current may.
    @Test func aSupersededMarkNeverTurnsOff() async {
        var offCalled = false
        await TranscriptMark.fade(on: {}, sleep: {}, isStillMarked: { false }, off: { offCalled = true })
        #expect(!offCalled)
    }
}
