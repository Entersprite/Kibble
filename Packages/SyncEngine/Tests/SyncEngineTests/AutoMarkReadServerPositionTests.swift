import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import SyncEngine

/// The automatic mark never publishes a position at or behind the one the
/// server already holds for the conversation. An opened search hit is
/// stored before its conversation's newest page lands, so a transcript can
/// hold nothing but a message years old; publishing it would move the
/// server's read position back and turn the conversation unread everywhere.
/// Equality is read (`findings.md` §42.2), and the thread mark already skips
/// the same way (§64.2).
@MainActor
@Suite(.timeLimit(.minutes(1)), .serialized)
struct AutoMarkReadServerPositionTests {
    static let conversation = autoMarkReadConversation
    static let serverPosition = Date(timeIntervalSince1970: 1_790_000_000)

    static func hit(at date: Date) -> Message {
        let base = FixtureWorld.minimal.messages[0]
        return Message(
            id: Message.ID("old-hit"), conversationID: conversation, threadID: MessageThread.ID("t-old-hit"),
            sender: base.sender, text: "found by search", createdAt: date
        )
    }

    /// The conversation with `readAt` as its stored read position and only
    /// the hit in its transcript: the newest page `select` asks for is held,
    /// as a slow `list_topics` would be.
    func opened(
        readAt: Date, hitAt: Date, hasUnread: Bool = false, debounce: Duration = .zero
    ) async throws -> TracedMarkReadHarness {
        let harness = try await makeTracedMarkReadHarness(markReadDebounce: debounce)
        await harness.backend.holdHistory(true)
        var writes: [StoreWrite] = [
            .setReadState(conversation: Self.conversation, lastReadAt: readAt, unread: 0)
        ]
        if hasUnread {
            writes.append(.markUnread(conversation: Self.conversation, sender: Member.ID("someone-else")))
        }
        writes.append(.insertMessageIfAbsent(Self.hit(at: hitAt)))
        try harness.store.apply(writes)
        await settleAutoMarkRead(until: "the read position is observed") {
            harness.model.conversations.first { $0.id == Self.conversation }?.readPosition == readAt
        }
        harness.model.select(Self.conversation)
        return harness
    }

    /// Decided before the wait, so nothing is even scheduled, and the
    /// session's watermark takes the server's position.
    @Test func anOldHitBehindTheServersPositionPublishesNothing() async throws {
        let harness = try await opened(
            readAt: Self.serverPosition, hitAt: Self.serverPosition.addingTimeInterval(-400 * 86400),
            debounce: markReadSequenceInterval
        )
        await settleAutoMarkRead(until: "the trigger skips") {
            markReadTriggerCount(.alreadyReadOnServer, in: harness) == 1
        }
        #expect(markReadTriggerCount(.scheduled, in: harness) == 0)
        #expect(harness.model.published[Self.conversation] == Self.serverPosition)
        // Asserting that nothing happens: one whole interval, then none sent.
        try await Task.sleep(for: markReadSequenceInterval * 2)
        #expect(await markReadPositions(from: harness.backend).isEmpty)
        await harness.model.stop()
    }

    @Test func aNewestEqualToTheServersPositionIsSkipped() async throws {
        let harness = try await opened(readAt: Self.serverPosition, hitAt: Self.serverPosition)
        await settleAutoMarkRead(until: "the trigger skips") {
            markReadTriggerCount(.alreadyReadOnServer, in: harness) == 1
        }
        await settleAutoMarkRead()
        #expect(await markReadPositions(from: harness.backend).isEmpty)
        await harness.model.stop()
    }

    @Test func aNewestAfterTheServersPositionIsPublished() async throws {
        let newest = Self.serverPosition.addingTimeInterval(60)
        let harness = try await opened(readAt: Self.serverPosition, hitAt: newest)
        await settleAutoMarkRead(until: "the mark is sent") {
            await markReadPositions(from: harness.backend) == [newest]
        }
        #expect(markReadTriggerCount(.alreadyReadOnServer, in: harness) == 0)
        await harness.model.stop()
    }

    /// Unread for newer messages the transcript does not hold yet: still not
    /// marked back to the old one. The skip reads the position, never the dot.
    @Test func anUnreadConversationIsNotMarkedBehindItsPosition() async throws {
        let harness = try await opened(
            readAt: Self.serverPosition, hitAt: Self.serverPosition.addingTimeInterval(-400 * 86400),
            hasUnread: true
        )
        await settleAutoMarkRead(until: "the trigger skips") {
            markReadTriggerCount(.alreadyReadOnServer, in: harness) == 1
        }
        await settleAutoMarkRead()
        #expect(await markReadPositions(from: harness.backend).isEmpty)
        await harness.model.stop()
    }

    /// Marked unread, as the store can know it: the server's position moved
    /// back before the newest message (the store keeps no other mark for a
    /// conversation). Viewing it marks it read again.
    @Test func aConversationMarkedUnreadIsMarkedOnView() async throws {
        let newest = Self.serverPosition
        let harness = try await opened(readAt: newest.addingTimeInterval(-1), hitAt: newest, hasUnread: true)
        await settleAutoMarkRead(until: "the mark is sent") {
            await markReadPositions(from: harness.backend) == [newest]
        }
        await harness.model.stop()
    }

    /// The position can move during the wait - a world load, or another
    /// device reading the conversation - so the check runs again after it.
    @Test func aPositionThatPassesTheMarkDuringTheWaitStopsIt() async throws {
        let newest = Self.serverPosition
        let harness = try await opened(
            readAt: newest.addingTimeInterval(-60), hitAt: newest, debounce: .seconds(2)
        )
        await settleAutoMarkRead(until: "the mark is scheduled") {
            markReadTriggerCount(.scheduled, in: harness) == 1
        }
        let moved = newest.addingTimeInterval(60)
        try harness.store.apply([.setReadState(
            conversation: Self.conversation,
            lastReadAt: moved,
            unread: 0
        )])
        await settleAutoMarkRead(until: "the moved position is observed") {
            harness.model.conversations.first { $0.id == Self.conversation }?.readPosition == moved
        }
        // Positive control: the wait has not ended yet, so the check after it
        // is the one that decides.
        try #require(markReadTriggerCount(.alreadyReadOnServer, in: harness) == 0)
        try #require(harness.model.markTasks[Self.conversation] != nil)
        await settleAutoMarkRead(until: "the wait ends", within: .seconds(10)) {
            harness.model.markTasks[Self.conversation] == nil
        }
        #expect(markReadTriggerCount(.alreadyReadOnServer, in: harness) == 1)
        #expect(await markReadPositions(from: harness.backend).isEmpty)
        #expect(harness.model.published[Self.conversation] == moved)
        await harness.model.stop()
    }
}
