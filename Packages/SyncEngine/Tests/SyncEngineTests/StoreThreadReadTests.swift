import ChatKit
import Foundation
import Testing
@testable import SyncEngine

/// The thread reads (threads spec §4.1): the transcript without replies, one
/// thread's messages, and the per-conversation summaries the marks draw from.
@Suite(.timeLimit(.minutes(1)))
struct StoreThreadReadTests {
    private let space = Conversation.ID("space/s")
    private let topic = MessageThread.ID("topic:1")
    private let me = Member.ID("users/me")
    private let alice = Member.ID("users/alice")
    private let bob = Member.ID("users/bob")
    private let carol = Member.ID("users/carol")
    private let dave = Member.ID("users/dave")
    /// Off a millisecond on purpose (`StoreDatePrecisionTests`).
    private let start = Date(timeIntervalSince1970: 1_790_000_000.128263)

    private func at(_ minute: Int) -> Date {
        start.addingTimeInterval(TimeInterval(minute * 60))
    }

    /// In `topic`: a reply, or the first message when `isReply` is false.
    private func message(_ id: String, from sender: Member.ID, minute: Int, isReply: Bool = true) -> Message {
        Message(
            id: Message.ID(id), conversationID: space, threadID: topic, sender: sender, text: "hi",
            createdAt: at(minute), isReply: isReply
        )
    }

    private func root(from sender: Member.ID? = nil) -> Message {
        message("m:root", from: sender ?? alice, minute: 0, isReply: false)
    }

    private func store(_ messages: [Message], _ writes: [StoreWrite] = []) throws -> ChatStore {
        let store = try ChatStore.inMemory()
        let base: [StoreWrite] = [
            .setLocalMember(me), .replaceConversations([Conversation(id: space, kind: .space)])
        ]
        try store.apply(base + messages.map { StoreWrite.upsertMessage($0) } + writes)
        return store
    }

    private func change(_ change: ThreadChange) -> StoreWrite {
        .applyThreadChange(thread: topic, conversation: space, change: change)
    }

    // MARK: - The transcript and the thread

    /// Replies live in their thread; the transcript is the top-level messages.
    /// Seen red with the filter deleted (Step 15).
    @Test func theTranscriptLeavesRepliesOutAndTheThreadHoldsThemOldestFirst() throws {
        var other = message("m:other", from: carol, minute: 2, isReply: false)
        other.threadID = MessageThread.ID("topic:2")
        let store = try store([message("m:r1", from: bob, minute: 1), root(), other])
        #expect(try store.messages(in: space).map(\.id.rawValue) == ["m:root", "m:other"])
        #expect(try store.threadMessages(topic, in: space).map(\.id.rawValue) == ["m:root", "m:r1"])
    }

    /// A row history rewrites as a reply leaves the transcript - the way a
    /// reply stored before v13 does (spec §7).
    @Test func aMessageRewrittenAsAReplyLeavesTheTranscript() throws {
        let store = try store([root(), message("m:r1", from: bob, minute: 1, isReply: false)])
        #expect(try store.messages(in: space).count == 2)
        try store.apply([.upsertMessage(message("m:r1", from: bob, minute: 1))])
        #expect(try store.messages(in: space).map(\.id.rawValue) == ["m:root"])
    }

    // MARK: - Summaries

    /// Count, newest time and three distinct repliers, newest first; a deleted
    /// reply leaves all three (ruling 4).
    @Test func aSummaryCountsTimesAndNamesThreeRecentRepliers() throws {
        var deleted = message("m:r5", from: me, minute: 5)
        deleted.isDeleted = true
        let store = try store([
            root(), message("m:r1", from: bob, minute: 1), message("m:r2", from: carol, minute: 2),
            message("m:r3", from: bob, minute: 3), message("m:r4", from: dave, minute: 4), deleted
        ])
        let summary = try #require(try store.threadSummaries(in: space)[topic])
        #expect(summary.replyCount == 5)
        #expect(microseconds(summary.lastActivity) == microseconds(at(4)))
        #expect(summary.recentRepliers == [dave, bob, carol])
    }

    /// The count always includes the first message, so a thread whose first
    /// message was deleted counts it still: the tombstone keeps its place
    /// (plan Review Focus 1).
    @Test func aDeletedFirstMessageStillCounts() throws {
        var gone = root()
        gone.isDeleted = true
        let store = try store([
            gone,
            message("m:r1", from: bob, minute: 1),
            message("m:r2", from: carol, minute: 2)
        ])
        #expect(try store.thread(topic, in: space)?.replyCount == 3)
    }

    /// The store holds pages; the server's count wins when it is larger.
    @Test func theCountIsTheLargerOfWhatIsStoredAndWhatTheServerCounted() throws {
        let store = try store([root(), message("m:r1", from: bob, minute: 1)])
        try store.apply([change(.counted(messages: 7, unread: nil))])
        #expect(try store.thread(topic, in: space)?.replyCount == 7)
        try store.apply([change(.counted(messages: 1, unread: nil))])
        #expect(try store.thread(topic, in: space)?.replyCount == 2)
    }

    /// Ruling 5: no summary unless a reply is stored or the server said
    /// something about the thread.
    @Test func onlyAThreadWithAReplyOrARowHasASummary() throws {
        var quiet = message("m:quiet", from: bob, minute: 1, isReply: false)
        quiet.threadID = MessageThread.ID("topic:quiet")
        var followed = message("m:followed", from: bob, minute: 2, isReply: false)
        followed.threadID = MessageThread.ID("topic:followed")
        let store = try store([root(), quiet, followed], [
            .applyThreadChange(thread: followed.threadID, conversation: space, change: .followed(true))
        ])
        #expect(try Set(store.threadSummaries(in: space).keys) == [followed.threadID])
        #expect(try store.thread(topic, in: space) == nil)
    }

    /// One definition: the single read is the dictionary's entry.
    @Test func oneThreadReadsExactlyAsItsSummary() throws {
        let store = try store([root(), message("m:r1", from: bob, minute: 1)], [
            change(.counted(messages: 3, unread: 1)), change(.read(upTo: at(1))), change(.followed(true))
        ])
        let one = try store.thread(topic, in: space)
        #expect(one != nil)
        #expect(try one == store.threadSummaries(in: space)[topic])
    }

    /// Ruling 1: following comes out resolved - the server's word, else
    /// whether you posted in the thread.
    @Test func followingFallsBackToHavingPostedInTheThread() throws {
        let started = try store([root(from: me), message("m:r1", from: bob, minute: 1)])
        #expect(try started.thread(topic, in: space)?.isFollowed == true)
        let replied = try store([root(), message("m:r1", from: me, minute: 1)])
        #expect(try replied.thread(topic, in: space)?.isFollowed == true)
        let stranger = try store([root(), message("m:r1", from: bob, minute: 1)])
        #expect(try stranger.thread(topic, in: space)?.isFollowed == false)
        try started.apply([change(.followed(false))])
        #expect(try started.thread(topic, in: space)?.isFollowed == false)
    }

    /// The rule on stored values, through both inputs the store computes: the
    /// newest reply from someone else, and whether you posted.
    @Test func aSummaryIsUnreadByTheRuleAndYourOwnReplyIsNotUnread() throws {
        let store = try store([root(), message("m:r1", from: bob, minute: 2)], [
            change(.followed(true)), change(.read(upTo: at(1)))
        ])
        #expect(try store.thread(topic, in: space)?.hasUnread == true)
        try store.apply([change(.read(upTo: at(2)))])
        #expect(try store.thread(topic, in: space)?.hasUnread == false)
        try store.apply([.upsertMessage(message("m:mine", from: me, minute: 3))])
        #expect(try store.thread(topic, in: space)?.hasUnread == false)
        try store.apply([change(.markedUnread(at: at(2)))])
        #expect(try store.thread(topic, in: space)?.hasUnread == true)
    }

    /// Through the store and back to the microsecond (`StoredDate`).
    @Test func aSummarysDatesSurviveTheStoreToTheMicrosecond() throws {
        let store = try store([root(), message("m:r1", from: bob, minute: 1)], [
            change(.read(upTo: start)), change(.markedUnread(at: start))
        ])
        let summary = try #require(try store.thread(topic, in: space))
        #expect(microseconds(summary.readPosition) == 1_790_000_000_128_263)
        #expect(microseconds(summary.markedUnreadAt) == 1_790_000_000_128_263)
        #expect(microseconds(summary.lastActivity) == microseconds(at(1)))
    }

    // MARK: - Observation

    /// A reply landing re-emits the summaries and the thread: the mark and the
    /// panel follow the store, never a read per bubble.
    @Test func aReplyLandingReEmitsTheSummariesAndTheThread() async throws {
        let store = try store([root(), message("m:r1", from: bob, minute: 1)])
        var summaries = store.observeThreadSummaries(in: space).makeAsyncIterator()
        var thread = store.observeThread(topic, in: space).makeAsyncIterator()
        #expect(try await summaries.next()?[topic]?.replyCount == 2)
        #expect(try await thread.next()?.count == 2)

        try store.apply([.upsertMessage(message("m:r2", from: carol, minute: 2))])

        #expect(try await summaries.next()?[topic]?.replyCount == 3)
        #expect(try await thread.next()?.map(\.id.rawValue) == ["m:root", "m:r1", "m:r2"])
    }
}
