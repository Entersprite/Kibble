import Foundation
import Testing
@testable import ChatKit

/// `Conversation.markReadPosition(through:)`: a mark of the whole
/// conversation covers the backend's newest main message even when no
/// message a client holds is that new.
struct ConversationMarkReadPositionTests {
    private let held = Date(timeIntervalSince1970: 1_790_000_000.000_100)
    private let head = Date(timeIntervalSince1970: 1_790_000_060.000_200)

    private func conversation(head: Date?) -> Conversation {
        Conversation(id: Conversation.ID("space/a"), kind: .space, latestMainMessageAt: head)
    }

    @Test func aNewerHeadThanAnythingHeldIsTheMark() {
        #expect(conversation(head: head).markReadPosition(through: held) == head)
    }

    @Test func aHeldMessageNewerThanTheHeadIsTheMark() {
        // The head is only as fresh as the last directory load.
        #expect(conversation(head: held).markReadPosition(through: head) == head)
    }

    @Test func withoutAHeadTheHeldMessageIsTheMark() {
        #expect(conversation(head: nil).markReadPosition(through: held) == held)
    }

    @Test func aHeadAloneIsTheMarkAndNothingKnownIsNone() {
        #expect(conversation(head: head).markReadPosition(through: nil) == head)
        #expect(conversation(head: nil).markReadPosition(through: nil) == nil)
    }
}
