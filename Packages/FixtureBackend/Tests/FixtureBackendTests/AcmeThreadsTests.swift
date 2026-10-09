import ChatKit
import Foundation
import Testing
@testable import FixtureBackend

/// The demo world's threads (threads spec §6): replies marked, a followed
/// thread with unread replies, a long thread and a DM thread, each in the
/// shape the wire has - a topic named after its first message and shared
/// only by replies (`findings.md` §63.3).
struct AcmeThreadsTests {
    private let world = FixtureWorld.acme
    private let sync = MessageThread.ID("topic:sync")
    private let variance = MessageThread.ID("topic:variance")
    private let trim = MessageThread.ID("topic:trim")
    private let dmDan = MessageThread.ID("topic:dm-dan")

    @Test func topicSyncsReplyIsMarkedAndItsFirstMessageIsNot() {
        let thread = world.messages(in: sync, of: Acme.priceEngine)
        #expect(thread.map(\.id.rawValue) == ["msg:pe-1", "msg:pe-2"])
        #expect(thread.map(\.isReply) == [false, true])
    }

    /// Two top-level messages never share a topic on the wire. A world that
    /// broke it would draw a reply count under both.
    @Test func everyTopLevelMessageHasItsOwnThread() {
        let topLevel = world.messages.filter { !$0.isReply }
        #expect(Set(topLevel.map(\.threadID)).count == topLevel.count)
    }

    @Test func aFollowedThreadHasUnreadReplies() {
        #expect(world.threadState(variance).isFollowed)
        #expect(world.unreadReplies(in: variance, of: Acme.priceEngine) == 3)
        #expect(world.isUnread(variance, of: Acme.priceEngine))
        #expect(!world.isUnread(sync, of: Acme.priceEngine))
    }

    /// The literal flags agree with the rule the fake moves them by, so the
    /// first `.unreadThreadsChanged` a client sees is a real change.
    @Test func everyConversationsUnreadThreadFlagAgreesWithItsThreads() {
        for conversation in world.conversations {
            #expect(
                conversation.hasUnreadThread == world.hasUnreadThread(in: conversation.id),
                "\(conversation.id)"
            )
        }
        #expect(world.conversation(Acme.priceEngine)?.hasUnreadThread == true)
    }

    @Test func theLongThreadHasThirtyRepliesAfterItsFirstMessage() {
        let thread = world.messages(in: trim, of: Acme.catalog)
        #expect(thread.count == 31)
        #expect(thread.first?.id == Message.ID("msg:trim-root"))
        #expect(thread.first?.isReply == false)
        let repliesAfterTheFirst = thread.dropFirst().allSatisfy(\.isReply)
        #expect(repliesAfterTheFirst)
        #expect(thread == thread.sorted { $0.createdAt < $1.createdAt })
    }

    @Test func aDirectMessageHasAThread() {
        #expect(world.conversation(Acme.danDM)?.kind == .directMessage)
        let thread = world.messages(in: dmDan, of: Acme.danDM)
        #expect(thread.map(\.id.rawValue) == ["msg:dd-1", "msg:dd-2", "msg:dd-3"])
        #expect(thread.map(\.isReply) == [false, true, true])
    }

    /// Replies everywhere but the Meet chat (`findings.md` §63.2).
    @Test func repliesAreEnabledEverywhereButTheMeetChat() {
        for conversation in world.conversations {
            #expect(conversation.repliesEnabled == (conversation.id != Acme.standup), "\(conversation.id)")
        }
    }

    /// The new threads moved nothing the rest of the suite counts on.
    @Test func theWorldStillStartsWhereItDid() {
        #expect(world.startedAt == Acme.at(66))
    }

    /// Kept free of threads on purpose: the SyncEngine suite counts it.
    @Test func theMinimalWorldHasNoReplies() {
        let hasAReply = FixtureWorld.minimal.messages.contains { $0.isReply }
        #expect(!hasAReply)
        #expect(FixtureWorld.minimal.threadStates.isEmpty)
    }
}

/// `inconsistencies()` covers thread state too.
struct FixtureThreadConsistencyTests {
    @Test func aThreadStateNamingNoMessageIsReported() {
        var world = FixtureWorld.minimal
        world.threadStates[MessageThread.ID("topic:nowhere")] = FixtureThreadState(isFollowed: true)
        #expect(world.inconsistencies().contains { $0.contains("topic:nowhere") })
    }

    @Test func aReplyWithNoFirstMessageIsReported() {
        var world = FixtureWorld.minimal
        world.messages[0].threadID = MessageThread.ID("topic:orphan")
        world.messages[0].isReply = true
        #expect(world.inconsistencies().contains { $0.contains("topic:orphan") })
    }
}
