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
}
