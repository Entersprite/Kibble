import ChatKit
import Foundation
import Testing
@testable import FixtureBackend

/// Replies, sent and arriving: marked as replies because the command says
/// so, counted against their thread rather than their conversation, and
/// reported the way the server pushes them (`findings.md` §63.10).
@Suite(.timeLimit(.minutes(1)))
struct FixtureReplyTests {
    private let sync = MessageThread.ID("topic:sync")
    private let pe = Acme.priceEngine

    private func connected(world: FixtureWorld = .acme) async throws -> (FakeBackend, EventCollector) {
        let backend = FakeBackend(world: world)
        let collector = EventCollector(backend.events)
        try await backend.connect()
        _ = await collector.next(backend.emittedCount)
        return (backend, collector)
    }

    @Test func aReplyYouSendIsMarkedReadsItsThreadAndFollowsIt() async throws {
        let (backend, collector) = try await connected()
        try await backend.send(.sendMessage(
            conversationID: pe,
            threadID: sync,
            text: "Mostly.",
            localID: "r-1"
        ))

        let events = await collector.next(5)
        try #require(events.count == 5)
        guard case let .messageReceived(reply) = events[0],
              case let .conversationUpdated(conversation) = events[1]
        else {
            Issue.record("expected messageReceived then conversationUpdated, got \(events)")
            return
        }
        #expect(reply.isReply)
        #expect(reply.threadID == sync)
        #expect(reply.localID == "r-1")
        #expect(conversation.unreadCount == 0)
        #expect(Array(events[2...]) == [
            .threadChanged(threadID: sync, conversationID: pe, change: .read(upTo: reply.createdAt)),
            .threadChanged(threadID: sync, conversationID: pe, change: .followed(true)),
            .threadChanged(threadID: sync, conversationID: pe, change: .counted(messages: 3, unread: 0))
        ])
        try await backend.apply(.gap(scope: .everything, reason: "sentinel"))
        #expect(await collector.nextOne() == .gap(scope: .everything, reason: "sentinel"))
    }

    @Test func aNewTopicIsNotAReply() async throws {
        let (backend, collector) = try await connected(world: .minimal)
        try await backend.send(
            .sendMessage(conversationID: Conversation.ID("dm:1"), threadID: nil, text: "a", localID: nil)
        )
        guard case let .messageReceived(message) = await collector.nextOne() else {
            Issue.record("expected messageReceived")
            return
        }
        #expect(!message.isReply)
    }

    @Test func aReplyIntoAThreadTheWorldDoesNotHoldIsRefused() async throws {
        let (backend, _) = try await connected()
        await #expect(throws: ChatError.self) {
            try await backend.send(.sendMessage(
                conversationID: pe, threadID: MessageThread.ID("topic:nowhere"), text: "x", localID: nil
            ))
        }
    }

    /// Someone else's reply makes its followed thread unread, and never its
    /// conversation (threads spec §4.3).
    @Test func aReplyArrivingCountsAgainstItsThreadNotItsConversation() async throws {
        let (backend, collector) = try await connected()
        let dmDan = MessageThread.ID("topic:dm-dan")
        try await backend.apply(
            .incomingMessage(conversation: Acme.danDM, from: Acme.dan, text: "Done.", thread: dmDan)
        )

        let events = await collector.next(4)
        try #require(events.count == 4)
        guard case let .messageReceived(reply) = events[0],
              case let .conversationUpdated(conversation) = events[1]
        else {
            Issue.record("expected messageReceived then conversationUpdated, got \(events)")
            return
        }
        #expect(reply.isReply)
        #expect(conversation.unreadCount == 0)
        #expect(conversation.lastActivity == reply.createdAt)
        #expect(Array(events[2...]) == [
            .threadChanged(
                threadID: dmDan,
                conversationID: Acme.danDM,
                change: .counted(messages: 4, unread: 1)
            ),
            .unreadThreadsChanged(conversationID: Acme.danDM, hasUnread: true)
        ])
    }

    @Test func theReplyScriptPlaysAgainstTheDemoWorldAndPostsReplies() async throws {
        let backend = FakeBackend(world: .acme)
        try await backend.connect()
        let before = await backend.currentWorld.messages.count
        try await backend.play(.acmeReplyArrives)
        let added = await backend.currentWorld.messages.dropFirst(before)
        #expect(added.count == 2)
        let repliesAdded = added.allSatisfy(\.isReply)
        #expect(repliesAdded)
    }

    /// The Debug app plays `acmeDemo`, so the reply script has to be in it.
    @Test func theDemoScriptEndsWithTheReplyScript() {
        let demo = FixtureScript.acmeDemo.steps
        let replies = FixtureScript.acmeReplyArrives.steps
        #expect(Array(demo.suffix(replies.count)) == replies)
    }
}
