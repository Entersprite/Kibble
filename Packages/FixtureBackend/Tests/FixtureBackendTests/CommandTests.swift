import ChatKit
import Foundation
import Testing
@testable import FixtureBackend

/// `send(_:)`, and the two reasons it is allowed to throw: the command could
/// not be submitted because there is no connection, or because `capabilities`
/// says the backend cannot do it. Everything else arrives as an event.
@Suite(.timeLimit(.minutes(1)))
struct CommandTests {
    private let dm = Conversation.ID("dm:1")
    private let space = Conversation.ID("space:1")
    private let seed = Message.ID("fixture-seed-1")

    /// A connected backend and a collector already past the connect snapshot.
    private func connected(
        capabilities: Capabilities = .fixture
    ) async throws -> (FakeBackend, EventCollector) {
        let backend = FakeBackend(world: .minimal, capabilities: capabilities)
        let collector = EventCollector(backend.events)
        try await backend.connect()
        _ = await collector.next(6)
        return (backend, collector)
    }

    // MARK: - Sending

    @Test func sendMessageEchoesTheLocalIDAndLandsInHistory() async throws {
        let (backend, collector) = try await connected()

        try await backend.send(
            .sendMessage(conversationID: dm, threadID: nil, text: "hello", localID: "draft-1")
        )

        guard case let .messageReceived(message) = await collector.nextOne() else {
            Issue.record("expected messageReceived")
            return
        }
        // The echo is what lets a client replace its optimistic copy instead of
        // showing the message twice.
        #expect(message.localID == "draft-1")
        #expect(message.sender == FixtureWorld.minimal.me)
        #expect(message.text == "hello")
        #expect(message.conversationID == dm)

        let history = try await backend.loadMessages(in: dm, before: nil)
        #expect(history.last == message)
    }

    @Test func sendingBumpsTheConversationsLastActivity() async throws {
        let (backend, collector) = try await connected()

        try await backend.send(
            .sendMessage(conversationID: dm, threadID: nil, text: "hello", localID: nil)
        )

        let events = await collector.next(2)
        try #require(events.count == 2)
        guard case let .messageReceived(message) = events[0],
              case let .conversationUpdated(conversation) = events[1]
        else {
            Issue.record("expected messageReceived then conversationUpdated, got \(events)")
            return
        }
        #expect(conversation.id == dm)
        #expect(conversation.lastActivity == message.createdAt)
    }

    @Test func aMessageWithNoThreadStartsOne() async throws {
        let (backend, collector) = try await connected()

        try await backend.send(
            .sendMessage(conversationID: dm, threadID: nil, text: "a", localID: nil)
        )
        try await backend.send(
            .sendMessage(conversationID: dm, threadID: nil, text: "b", localID: nil)
        )

        let events = await collector.next(4)
        let threads = events.compactMap { event -> MessageThread.ID? in
            if case let .messageReceived(message) = event {
                return message.threadID
            }
            return nil
        }
        try #require(threads.count == 2)
        #expect(threads[0] != threads[1])
    }

    @Test func aMessageSentIntoAThreadKeepsThatThread() async throws {
        let (backend, collector) = try await connected()
        let thread = MessageThread.ID("fixture-seed-topic-3")

        try await backend.send(
            .sendMessage(conversationID: space, threadID: thread, text: "reply", localID: nil)
        )

        guard case let .messageReceived(message) = await collector.nextOne() else {
            Issue.record("expected messageReceived")
            return
        }
        #expect(message.threadID == thread)
    }

    @Test func replyingInAThreadNeedsThreadSupport() async throws {
        let capabilities = Capabilities(canSendMessages: true) // supportsThreads false
        let (backend, _) = try await connected(capabilities: capabilities)

        await #expect(throws: ChatError.unsupported(capability: "supportsThreads")) {
            try await backend.send(
                .sendMessage(
                    conversationID: space,
                    threadID: MessageThread.ID("fixture-seed-topic-3"),
                    text: "reply",
                    localID: nil
                )
            )
        }
    }

    @Test func sendingToAConversationThatDoesNotExistThrows() async throws {
        let (backend, _) = try await connected()
        await #expect(throws: ChatError.self) {
            try await backend.send(
                .sendMessage(
                    conversationID: Conversation.ID("space:nowhere"),
                    threadID: nil,
                    text: "hello",
                    localID: nil
                )
            )
        }
    }

    // MARK: - Editing, deleting, reacting

    @Test func editingSetsTheTextAndTheEditedTimestamp() async throws {
        let (backend, collector) = try await connected()

        try await backend.send(.editMessage(id: seed, text: "corrected"))

        guard case let .messageUpdated(message) = await collector.nextOne() else {
            Issue.record("expected messageUpdated")
            return
        }
        #expect(message.text == "corrected")
        #expect(message.editedAt != nil)
        #expect(message.editedAt != message.createdAt)
    }

    @Test func anEditCarriesItsMentions() async throws {
        let (backend, collector) = try await connected()
        let mention = Mention(target: .user(Member.ID("fixture-other")), start: 0, length: 6)

        try await backend.send(.editMessage(id: seed, text: "@Other hi", mentions: [mention]))

        guard case let .messageUpdated(message) = await collector.nextOne() else {
            Issue.record("expected messageUpdated")
            return
        }
        #expect(message.mentions == [mention])
    }

    /// A deleted message keeps its place. The protocol keeps sending it, and a
    /// client that dropped it would leave a hole in its paging.
    @Test func deletingTombstonesInPlace() async throws {
        let (backend, collector) = try await connected()
        let before = try await backend.loadMessages(in: dm, before: nil).count

        try await backend.send(.deleteMessage(id: seed))

        #expect(await collector.nextOne() == .messageDeleted(id: seed, in: dm))
        let after = try await backend.loadMessages(in: dm, before: nil)
        #expect(after.count == before)
        #expect(after.first { $0.id == seed }?.isDeleted == true)
        #expect(after.first { $0.id == seed }?.text.isEmpty == true)
    }

    @Test func reactingAddsMeToTheReactionSet() async throws {
        let (backend, collector) = try await connected()

        try await backend.send(.setReaction(messageID: seed, emoji: "👍", add: true))

        guard case let .reactionChanged(messageID, reactions) = await collector.nextOne() else {
            Issue.record("expected reactionChanged")
            return
        }
        #expect(messageID == seed)
        #expect(reactions == [Reaction(emoji: "👍", count: 1, includesMe: true)])
    }

    @Test func reactingTwiceIsIdempotent() async throws {
        let (backend, collector) = try await connected()

        try await backend.send(.setReaction(messageID: seed, emoji: "👍", add: true))
        try await backend.send(.setReaction(messageID: seed, emoji: "👍", add: true))

        let events = await collector.next(2)
        try #require(events.count == 2)
        guard case let .reactionChanged(_, reactions) = events[1] else {
            Issue.record("expected reactionChanged")
            return
        }
        #expect(reactions == [Reaction(emoji: "👍", count: 1, includesMe: true)])
    }

    /// A custom reaction is appended with its identity, so the row can tell
    /// two `:parrot:`s apart.
    @Test func aCustomReactionIsAddedByIdentity() async throws {
        let (backend, collector) = try await connected()
        let parrot = CustomEmojiRef(id: "e-1", shortcode: ":parrot:")

        try await backend.send(.setReaction(
            messageID: seed, emoji: parrot.displayText, add: true, customEmoji: parrot
        ))

        guard case let .reactionChanged(_, reactions) = await collector.nextOne() else {
            Issue.record("expected reactionChanged")
            return
        }
        #expect(reactions == [Reaction(emoji: ":parrot:", count: 1, includesMe: true, customEmoji: parrot)])
    }

    @Test func removingTheLastReactionRemovesTheEntry() async throws {
        let (backend, collector) = try await connected()

        try await backend.send(.setReaction(messageID: seed, emoji: "👍", add: true))
        try await backend.send(.setReaction(messageID: seed, emoji: "👍", add: false))

        let events = await collector.next(2)
        try #require(events.count == 2)
        guard case let .reactionChanged(_, reactions) = events[1] else {
            Issue.record("expected reactionChanged")
            return
        }
        #expect(reactions.isEmpty)
    }

    // MARK: - State

    /// A backend does not echo your own typing back at you, so this emits
    /// nothing. Asserted without a timeout: any event here would fail the
    /// sentinel that follows.
    @Test func settingYourOwnTypingStateEmitsNothing() async throws {
        let (backend, collector) = try await connected()

        try await backend.send(.setTyping(conversationID: dm, threadID: nil, isTyping: true))
        await backend.disconnect()

        #expect(await collector.nextOne() == .connectionStateChanged(.disconnected(reason: nil, issue: nil)))
    }

    @Test func markingReadZeroesTheUnreadCount() async throws {
        let (backend, collector) = try await connected()
        let readAt = FixtureWorld.minimal.startedAt

        try await backend.send(.markRead(conversationID: space, upTo: readAt))

        #expect(
            await collector.nextOne()
                == .readStateChanged(conversationID: space, lastReadAt: readAt, unread: 0)
        )
        let reloaded = try await backend.loadConversations().first { $0.id == space }
        #expect(reloaded?.unreadCount == 0)
    }

    @Test func theNotificationLevelCommandLandsWhereTheMethodDoes() async throws {
        let (backend, collector) = try await connected()

        try await backend.send(.setNotificationLevel(conversationID: space, level: .never))

        guard case let .conversationUpdated(conversation) = await collector.nextOne() else {
            Issue.record("expected conversationUpdated")
            return
        }
        #expect(conversation.notificationLevel == .never)
    }

    /// A command from a newer client. The backend must be able to say precisely
    /// what it was asked and could not do, rather than failing to parse.
    @Test func anUnknownCommandIsRejectedByName() async throws {
        let (backend, _) = try await connected()

        await #expect(throws: ChatError.unsupported(capability: "startHuddle")) {
            try await backend.send(.unknown(type: "startHuddle", payload: .object([:])))
        }
    }

    // MARK: - Rejection

    @Test(arguments: CommandSamples.all)
    func everyCommandIsRejectedWhileDisconnected(sample: CommandSamples.Sample) async throws {
        let backend = FakeBackend(world: .minimal)
        await #expect(throws: ChatError.transport("not connected")) {
            try await backend.send(sample.command)
        }
    }

    @Test(arguments: CommandSamples.all)
    func everyCommandIsRejectedWhenItsCapabilityIsOff(
        sample: CommandSamples.Sample
    ) async throws {
        // Every flag false: whichever one this command needs, it does not have.
        let (backend, _) = try await connected(capabilities: Capabilities())
        await #expect(throws: ChatError.unsupported(capability: sample.capability)) {
            try await backend.send(sample.command)
        }
    }

    /// The coverage claim. The compiler already forces `send`'s switch to be
    /// exhaustive, so a new `ChatCommand` case cannot be silently unhandled -
    /// this asserts the *tests* saw one of each too, and the hand-written count
    /// is what fails when someone adds a case and forgets a sample.
    @Test func everyCommandCaseHasASample() {
        #expect(CommandSamples.all.count == 8)
        #expect(Set(CommandSamples.all.map(\.name)).count == CommandSamples.all.count)
    }
}
