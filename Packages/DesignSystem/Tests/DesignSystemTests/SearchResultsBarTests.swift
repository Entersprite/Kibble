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

    @Test func openingAndUnreachableReplaceThePosition() {
        #expect(SearchBarText.position(SearchBarScene(query: Self.query, index: 0, count: 3, isOpening: true))
            == "Loading older messages…")
        #expect(SearchBarText.position(SearchBarScene(
            query: Self.query,
            index: 0,
            count: 3,
            unreachable: true
        ))
            == "Too far back to open here")
    }

    @Test func aMessageIsMarkedOnceWhenItIsThere() {
        let message = Message(
            id: Message.ID("m"), conversationID: Conversation.ID("c"), threadID: MessageThread.ID("m"),
            sender: Member.ID("s"), text: "x", createdAt: .now
        )
        #expect(TranscriptMark.shouldMark(message.id, in: [message], marked: nil))
        #expect(!TranscriptMark.shouldMark(message.id, in: [message], marked: message.id))
        #expect(!TranscriptMark.shouldMark(message.id, in: [], marked: nil))
        #expect(!TranscriptMark.shouldMark(nil, in: [message], marked: nil))
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

    /// Pins the round 1 review finding: `try?` around the sleep swallowed
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
