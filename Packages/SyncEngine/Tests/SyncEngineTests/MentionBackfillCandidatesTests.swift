import ChatKit
import Foundation
import Testing
@testable import SyncEngine

/// Which conversations a backfill fetches (the mentions-list spec §2).
struct MentionBackfillCandidatesTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func conversation(
        _ id: String, _ kind: Conversation.Kind = .space, active: Date?
    ) -> Conversation {
        Conversation(id: Conversation.ID(id), kind: kind, lastActivity: active)
    }

    /// Ruling 9. Both edges are pinned: exactly 30 days before `now` is in,
    /// one second older is out, and `now` itself is in.
    @Test func theWindowIncludesExactlyThirtyDaysAgoAndNowAndNothingOlderOrUnknown() {
        let candidates = MentionBackfill.candidates(in: [
            conversation("space/edge", active: now.addingTimeInterval(-2_592_000)),
            conversation("space/now", active: now),
            conversation("space/older", active: now.addingTimeInterval(-2_592_001)),
            conversation("space/never", active: nil)
        ], now: now)
        #expect(candidates == [Conversation.ID("space/now"), Conversation.ID("space/edge")])
    }

    @Test func aConversationActiveAfterNowIsACandidate() {
        let skewed = conversation("space/ahead", active: now.addingTimeInterval(60))
        #expect(MentionBackfill.candidates(in: [skewed], now: now) == [Conversation.ID("space/ahead")])
    }

    /// Following the web client (§44.4: 3 of 31 prefetched were Meet).
    @Test func meetChatsAreNotBackfilledAndEveryOtherKindIs() {
        let kinds: [Conversation.Kind] = [
            .directMessage, .groupDirectMessage, .appDirectMessage, .space, .unknown("meetCall"), .meetChat
        ]
        let conversations = kinds.enumerated().map { index, kind in
            conversation("c/\(index)", kind, active: now.addingTimeInterval(-Double(index)))
        }
        let candidates = MentionBackfill.candidates(in: conversations, now: now)
        #expect(candidates.count == 5)
        #expect(!candidates.contains(Conversation.ID("c/5")))
    }

    @Test func theNewestActivityComesFirstAndATieFallsBackToTheID() {
        let candidates = MentionBackfill.candidates(in: [
            conversation("space/b", active: now.addingTimeInterval(-60)),
            conversation("space/c", active: now),
            conversation("space/a", active: now.addingTimeInterval(-60))
        ], now: now)
        #expect(candidates.map(\.rawValue) == ["space/c", "space/a", "space/b"])
    }
}
