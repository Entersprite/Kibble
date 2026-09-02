import ChatKit
import Foundation
import Testing
@testable import FixtureBackend

/// A script is the server's half. Where `send(_:)` is the client asking for
/// something, `apply(_:)` is the world happening to it - someone else typing,
/// a connection dropping, catch-up giving up.
@Suite(.timeLimit(.minutes(1)))
struct ScriptTests {
    private let dm = Conversation.ID("dm:1")
    private let space = Conversation.ID("space:1")
    private let other = Member.ID("fixture-other")
    private let seed = Message.ID("fixture-seed-1")

    private func connected() async throws -> (FakeBackend, EventCollector) {
        let backend = FakeBackend(world: .minimal)
        let collector = EventCollector(backend.events)
        try await backend.connect()
        _ = await collector.next(6)
        return (backend, collector)
    }

    @Test func anIncomingMessageArrivesAndCountsAsUnread() async throws {
        let (backend, collector) = try await connected()

        try await backend.apply(
            .incomingMessage(conversation: dm, from: other, text: "you there?", thread: nil)
        )

        let events = await collector.next(2)
        try #require(events.count == 2)
        guard case let .messageReceived(message) = events[0],
              case let .conversationUpdated(conversation) = events[1]
        else {
            Issue.record("expected messageReceived then conversationUpdated, got \(events)")
            return
        }
        #expect(message.sender == other)
        // Not ours, so no localID to echo: that field is how a client tells its
        // own optimistic copy apart from someone else's message.
        #expect(message.localID == nil)
        #expect(conversation.unreadCount == 1)
        #expect(conversation.lastActivity == message.createdAt)
    }

    /// Our own message arriving from elsewhere - another device - must not
    /// count against us.
    @Test func aMessageFromTheLocalUserDoesNotIncrementUnread() async throws {
        let (backend, collector) = try await connected()

        try await backend.apply(
            .incomingMessage(
                conversation: dm,
                from: FixtureWorld.minimal.me,
                text: "sent from my phone",
                thread: nil
            )
        )

        let events = await collector.next(2)
        try #require(events.count == 2)
        guard case let .conversationUpdated(conversation) = events[1] else {
            Issue.record("expected conversationUpdated")
            return
        }
        #expect(conversation.unreadCount == 0)
    }

    @Test func someoneElseTypingIsReported() async throws {
        let (backend, collector) = try await connected()

        try await backend.apply(.typing(conversation: dm, member: other, isTyping: true))

        #expect(
            await collector.nextOne()
                == .typingChanged(conversationID: dm, member: other, isTyping: true)
        )
    }

    @Test func presenceUpdatesTheMemberRecordAsWellAsAnnouncingIt() async throws {
        let (backend, collector) = try await connected()

        try await backend.apply(.presence(member: other, presence: .doNotDisturb))

        #expect(await collector.nextOne() == .presenceChanged(member: other, presence: .doNotDisturb))
        #expect(await backend.currentWorld.member(other)?.presence == .doNotDisturb)
    }

    @Test func someoneElseReactingDoesNotClaimToBeUs() async throws {
        let (backend, collector) = try await connected()

        try await backend.apply(.reaction(messageID: seed, emoji: "🎉", by: other, add: true))

        guard case let .reactionChanged(_, reactions) = await collector.nextOne() else {
            Issue.record("expected reactionChanged")
            return
        }
        #expect(reactions == [Reaction(emoji: "🎉", count: 1, includesMe: false)])
    }

    @Test func readStateFromAnotherDeviceIsReported() async throws {
        let (backend, collector) = try await connected()

        try await backend.apply(.readState(conversation: space, unread: 0))

        guard case let .readStateChanged(conversationID, _, unread) = await collector.nextOne() else {
            Issue.record("expected readStateChanged")
            return
        }
        #expect(conversationID == space)
        #expect(unread == 0)
        #expect(try await backend.loadConversations().first { $0.id == space }?.unreadCount == 0)
    }

    @Test func aGapIsPassedStraightThrough() async throws {
        let (backend, collector) = try await connected()

        try await backend.apply(.gap(scope: .conversation(dm), reason: "catch-up aborted"))

        #expect(
            await collector.nextOne() == .gap(scope: .conversation(dm), reason: "catch-up aborted")
        )
    }

    @Test func aDropDisconnectsForRealRatherThanJustSayingSo() async throws {
        let (backend, collector) = try await connected()

        try await backend.apply(.drop(reason: "server closed the channel"))

        #expect(
            await collector.nextOne()
                == .connectionStateChanged(.disconnected(reason: "server closed the channel"))
        )
        // The state has to move too, or the next command would be accepted by a
        // backend the client has been told is gone.
        await #expect(throws: ChatError.transport("not connected")) {
            try await backend.send(.deleteMessage(id: seed))
        }
    }

    @Test func reconnectingIsReportedWithItsAttemptNumber() async throws {
        let (backend, collector) = try await connected()

        try await backend.apply(.reconnecting(attempt: 3))

        #expect(await collector.nextOne() == .connectionStateChanged(.reconnecting(attempt: 3)))
    }

    @Test func anErrorIsReportedWithoutEndingTheStream() async throws {
        let (backend, collector) = try await connected()

        try await backend.apply(.error(.rateLimited(retryAfter: .seconds(30))))
        try await backend.apply(.typing(conversation: dm, member: other, isTyping: false))

        let events = await collector.next(2)
        try #require(events.count == 2)
        #expect(events[0] == .backendError(.rateLimited(retryAfter: .seconds(30))))
        #expect(events[1] == .typingChanged(conversationID: dm, member: other, isTyping: false))
    }

    /// `.delay` is the demo driver's business. A test playing a script must not
    /// wait for anything.
    @Test func aDelayEmitsNothingWhenAScriptIsPlayedRatherThanDriven() async throws {
        let (backend, collector) = try await connected()
        let before = await backend.emittedCount

        try await backend.play(FixtureScript(steps: [.delay(.seconds(600))]))

        #expect(await backend.emittedCount == before)
        try await backend.apply(.gap(scope: .everything, reason: "sentinel"))
        #expect(await collector.nextOne() == .gap(scope: .everything, reason: "sentinel"))
    }

    @Test func aStepNamingSomethingTheWorldDoesNotHaveThrows() async throws {
        let (backend, _) = try await connected()

        await #expect(throws: ChatError.self) {
            try await backend.apply(
                .incomingMessage(
                    conversation: Conversation.ID("space:nowhere"),
                    from: other,
                    text: "x",
                    thread: nil
                )
            )
        }
        await #expect(throws: ChatError.self) {
            try await backend.apply(
                .incomingMessage(conversation: dm, from: Member.ID("ghost"), text: "x", thread: nil)
            )
        }
    }

    /// The script is the server: it does not consult the client's connection
    /// state, because a server does not know or care.
    @Test func stepsApplyWhetherOrNotTheClientHasConnected() async throws {
        let backend = FakeBackend(world: .minimal)
        let collector = EventCollector(backend.events)

        try await backend.apply(.typing(conversation: dm, member: other, isTyping: true))

        #expect(
            await collector.nextOne()
                == .typingChanged(conversationID: dm, member: other, isTyping: true)
        )
    }

    @Test func playingAScriptRunsEveryStepInOrder() async throws {
        let (backend, collector) = try await connected()

        try await backend.play(
            FixtureScript(steps: [
                .typing(conversation: dm, member: other, isTyping: true),
                .typing(conversation: dm, member: other, isTyping: false),
                .gap(scope: .everything, reason: "last")
            ])
        )

        let events = await collector.next(3)
        try #require(events.count == 3)
        #expect(events[0] == .typingChanged(conversationID: dm, member: other, isTyping: true))
        #expect(events[1] == .typingChanged(conversationID: dm, member: other, isTyping: false))
        #expect(events[2] == .gap(scope: .everything, reason: "last"))
    }
}
