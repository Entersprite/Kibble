import ChatKit
import Foundation
import Testing
@testable import ChatRules

struct ConversationSnapshotMergeTests {
    private let first = Conversation(id: .init("first"), kind: .space, title: "Original")
    private let second = Conversation(id: .init("second"), kind: .space)

    @Test func partialCoverageRetainsAbsentRowsAndCompleteCoverageRemovesThem() {
        let baseline = [first, second]
        #expect(ConversationSnapshot(conversations: [first])
            .merging(current: baseline, baseline: baseline) == baseline)
        #expect(ConversationSnapshot(conversations: [first], isComplete: true)
            .merging(current: baseline, baseline: baseline) == [first])
    }

    @Test func concurrentReadProgressDoesNotDiscardFetchedTitle() {
        var fetched = first
        fetched.title = "Renamed"
        fetched.unreadCount = 7; fetched.hasUnread = true
        var current = first
        current.readPosition = Date(timeIntervalSince1970: 42)
        let result = ConversationSnapshot(conversations: [fetched], isComplete: true)
            .merging(current: [current], baseline: [first])
        #expect(result.first?.title == "Renamed")
        #expect(result.first?.readPosition == current.readPosition)
        #expect(result.first?.unreadCount == current.unreadCount)
        #expect(result.first?.hasUnread == current.hasUnread)
    }

    @Test func concurrentRemovalAndInsertionSurviveAnOlderCompleteRead() {
        #expect(ConversationSnapshot(conversations: [first], isComplete: true)
            .merging(current: [second], baseline: [first]) == [second])
    }

    @Test func explicitRemovalWorksInPartialCoverage() {
        #expect(ConversationSnapshot(conversations: [], removedIDs: [first.id])
            .merging(current: [first, second], baseline: [first, second]) == [second])
    }

    @Test func summariesRetainResolvedDetailsWithoutRetainingOldUnreadState() {
        var resolved = first
        resolved.kind = .appDirectMessage
        resolved.members = [.init("app")]
        resolved.hasUnread = true
        var summary = first
        summary.kind = .directMessage
        summary.title = nil
        let result = ConversationSnapshot(conversations: [summary], preservesDetails: true)
            .merging(current: [resolved], baseline: [resolved])
        #expect(result.first?.kind == .appDirectMessage)
        #expect(result.first?.title == "Original")
        #expect(result.first?.members == resolved.members)
        #expect(result.first?.hasUnread == false)
    }
}
