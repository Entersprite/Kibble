import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import SyncEngine

/// The person's own reaction: written at once, sent addressed, undone on
/// refusal.
@MainActor
struct ReactTests {
    private struct Harness {
        let backend: RecordingBackend
        let store: ChatStore
        let model: ChatSessionModel
        let message: Message
    }

    private func running(capabilities: Capabilities = .fixture) async throws -> Harness {
        let backend = RecordingBackend(capabilities: capabilities)
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let model = ChatSessionModel(store: store, engine: engine, me: nil, markReadDebounce: .zero)
        try await model.start()
        await settleAutoMarkRead()
        let message = FixtureWorld.minimal.messages[0]
        model.select(message.conversationID)
        await settleAutoMarkRead()
        try #require(model.messages.contains { $0.id == message.id })
        return Harness(backend: backend, store: store, model: model, message: message)
    }

    private func stored(_ harness: Harness) throws -> [Reaction] {
        try harness.store.messages(in: harness.message.conversationID)
            .first { $0.id == harness.message.id }?.reactions ?? []
    }

    @Test func aReactionIsWrittenAtOnceAndSentAddressed() async throws {
        let harness = try await running()
        let before = try stored(harness)
        harness.model.react(to: harness.message.id, with: ReactionChoice(emoji: "🛞"), add: true)
        #expect(try stored(harness) == before.applying(ReactionChoice(emoji: "🛞"), add: true))
        await settleAutoMarkRead()
        let sent = await harness.backend.commands.last
        #expect(sent == .setReaction(
            messageID: harness.message.id, emoji: "🛞", add: true,
            conversationID: harness.message.conversationID, threadID: harness.message.threadID,
            customEmoji: nil
        ))
        await harness.model.stop()
    }

    @Test func aRefusalPutsThePreviousSetBack() async throws {
        let harness = try await running()
        let before = try stored(harness)
        await harness.backend.failSubmissions(true)
        harness.model.react(to: harness.message.id, with: ReactionChoice(emoji: "🛞"), add: true)
        await settleAutoMarkRead()
        #expect(try stored(harness) == before)
        #expect(harness.model.lastError != nil)
        #expect(await harness.backend.commands.contains {
            if case .setReaction = $0 {
                true
            } else {
                false
            }
        })
        await harness.model.stop()
    }

    /// The inverse-fold fix: a snapshot restore undoes to a fixed point, so a
    /// second refusal can put back more than its own click added. Folding the
    /// inverse of each toggle against whatever the store holds at refusal
    /// time undoes exactly its own effect regardless of order, so two
    /// different emoji - both refused, clicked with no settle between - still
    /// end back at the original set.
    @Test func twoRefusedTogglesOfDifferentEmojiEndAtTheOriginalSet() async throws {
        let harness = try await running()
        let before = try stored(harness)
        await harness.backend.failSubmissions(true)
        harness.model.react(to: harness.message.id, with: ReactionChoice(emoji: "🛞"), add: true)
        harness.model.react(to: harness.message.id, with: ReactionChoice(emoji: "👍"), add: true)
        await settleAutoMarkRead()
        #expect(try stored(harness) == before)
        await harness.model.stop()
    }

    /// Review Focus 2: the second toggle folds against the first's write.
    @Test func twoQuickTogglesCancelOut() async throws {
        let harness = try await running()
        let before = try stored(harness)
        harness.model.react(to: harness.message.id, with: ReactionChoice(emoji: "🛞"), add: true)
        await settleAutoMarkRead()
        harness.model.react(to: harness.message.id, with: ReactionChoice(emoji: "🛞"), add: false)
        await settleAutoMarkRead()
        #expect(try stored(harness) == before)
        await harness.model.stop()
    }

    /// Review Finding 1: a second toggle issued with **no settle** between the
    /// two calls must still fold against what the first one actually wrote to
    /// the store, not against `messages` - which a `ValueObservation` has not
    /// yet refreshed at this point.
    ///
    /// Asserted immediately, before any settle - the same reasoning
    /// `twoRapidAddsOfDifferentEmojiWithNoSettleEndWithBoth` below spells out:
    /// a settle gives the fixture backend's own `.reactionChanged` push a
    /// chance to land and quietly correct a bad local fold.
    @Test func twoRapidTogglesOfTheSameEmojiWithNoSettleEndAtTheOriginalSet() async throws {
        let harness = try await running()
        let before = try stored(harness)
        harness.model.react(to: harness.message.id, with: ReactionChoice(emoji: "🛞"), add: true)
        harness.model.react(to: harness.message.id, with: ReactionChoice(emoji: "🛞"), add: false)
        #expect(try stored(harness) == before)
        await settleAutoMarkRead()
        await harness.model.stop()
    }

    /// Review Finding 1, the other half: a second, *different* emoji's rapid
    /// add must not erase the first's. Reading `messages` instead of the
    /// store would fold the second add against `before` alone and overwrite
    /// the first emoji entirely.
    ///
    /// Asserted **before** any settle, same as
    /// `aReactionIsWrittenAtOnceAndSentAddressed` above: the fixture backend
    /// independently folds its own two commands in order and pushes the
    /// correct result back through `.reactionChanged`, which would overwrite
    /// a bad local fold and hide it the instant this test gave that push a
    /// chance to land.
    @Test func twoRapidAddsOfDifferentEmojiWithNoSettleEndWithBoth() async throws {
        let harness = try await running()
        let before = try stored(harness)
        harness.model.react(to: harness.message.id, with: ReactionChoice(emoji: "🛞"), add: true)
        harness.model.react(to: harness.message.id, with: ReactionChoice(emoji: "👍"), add: true)
        let expected = before
            .applying(ReactionChoice(emoji: "🛞"), add: true)
            .applying(ReactionChoice(emoji: "👍"), add: true)
        #expect(try stored(harness) == expected)
        await settleAutoMarkRead()
        await harness.model.stop()
    }

    /// Review Finding 2: `stop()` must cancel a reaction submission still
    /// held at the backend, the same reasoning `markTasks`' own doc comment
    /// gives for marks. Modelled on
    /// `SubmitCancellationTests.aSubmitCancelledBeforeItFailsDoesNotRecord`.
    @Test func stopCancelsAReactionSubmissionInFlight() async throws {
        let harness = try await running()
        let before = try stored(harness)
        await harness.backend.holdSubmissions(true)
        harness.model.react(to: harness.message.id, with: ReactionChoice(emoji: "🛞"), add: true)

        // Gives the task a moment to actually reach `send(_:)` and block
        // inside it, so the cancellation below finds a genuinely in-flight
        // call rather than one that has not started.
        for _ in 0 ..< 50 {
            await Task.yield()
        }

        await harness.model.stop()

        // The backend "finally answers" only now - after our own
        // cancellation - and answers with a failure, the shape a cancelled
        // `/api/` call actually takes.
        await harness.backend.failSubmissions(true)
        await harness.backend.releaseHeldSubmission()

        for _ in 0 ..< 50 {
            await Task.yield()
        }

        // Without the cancel, this failure would have reached
        // `SyncEngine.submit`'s own `guard !Task.isCancelled`, found it
        // false, and undone the optimistic write while recording the error -
        // into a session that has already moved on.
        #expect(try stored(harness) == before.applying(ReactionChoice(emoji: "🛞"), add: true))
        #expect(try harness.store.lastError() == nil)
    }

    /// A chained toggle not yet sent when `stop()` runs must never reach the
    /// backend afterward. Covers the `guard !Task.isCancelled` right after
    /// `await previousTail?.value` and before `engine.submit` in
    /// `submitReaction`: without it, a toggle queued behind one still held at
    /// the backend would be submitted into a session that has already moved
    /// on, the same trap `markTasks`' own guards close for marks.
    @Test func stopBeforeAChainedReactionIsSentSendsNothingFurther() async throws {
        let harness = try await running()
        await harness.backend.holdSubmissions(true)
        harness.model.react(to: harness.message.id, with: ReactionChoice(emoji: "🛞"), add: true)
        harness.model.react(to: harness.message.id, with: ReactionChoice(emoji: "👍"), add: true)
        await settleAutoMarkRead()
        await harness.model.stop()
        await harness.backend.releaseHeldSubmission()
        await settleAutoMarkRead()
        let setReactionCount = await harness.backend.commands.count {
            if case .setReaction = $0 {
                true
            } else {
                false
            }
        }
        #expect(setReactionCount == 1)
    }

    /// Review Finding 2, the ordering half: a second toggle must not even
    /// reach the backend until the first's `send(_:)` call has returned -
    /// which nothing here lets happen until the first release below - so an
    /// add and a remove clicked quickly in succession still arrive in that
    /// order rather than whatever order two unrelated `Task`s happen to be
    /// scheduled in.
    @Test func twoQuickTogglesReachTheBackendInOrder() async throws {
        let harness = try await running()
        // Baselined rather than compared from zero: `running()`'s own
        // selection already sends an auto-mark-read `.markRead` (zero
        // debounce), which would otherwise land ahead of both reactions and
        // break an exact-array comparison for a reason this test is not about.
        let baseline = await harness.backend.commands.count
        await harness.backend.holdSubmissions(true)
        harness.model.react(to: harness.message.id, with: ReactionChoice(emoji: "🛞"), add: true)
        harness.model.react(to: harness.message.id, with: ReactionChoice(emoji: "👍"), add: true)

        for _ in 0 ..< 50 {
            await Task.yield()
        }
        #expect(await harness.backend.commands.count == baseline + 1)

        await harness.backend.releaseHeldSubmission()
        await settleAutoMarkRead(until: "the second submission reaches the backend") {
            await harness.backend.commands.count == baseline + 2
        }
        await harness.backend.releaseHeldSubmission()
        await settleAutoMarkRead()

        let sent = await Array(harness.backend.commands.suffix(2))
        #expect(sent == [
            .setReaction(
                messageID: harness.message.id, emoji: "🛞", add: true,
                conversationID: harness.message.conversationID, threadID: harness.message.threadID,
                customEmoji: nil
            ),
            .setReaction(
                messageID: harness.message.id, emoji: "👍", add: true,
                conversationID: harness.message.conversationID, threadID: harness.message.threadID,
                customEmoji: nil
            )
        ])
        await harness.model.stop()
    }

    @Test func aToggleThatChangesNothingSendsNothing() async throws {
        let harness = try await running()
        harness.model.react(to: harness.message.id, with: ReactionChoice(emoji: "🛞"), add: false)
        await settleAutoMarkRead()
        #expect(await !harness.backend.commands
            .contains {
                if case .setReaction = $0 {
                    true
                } else {
                    false
                }
            })
        await harness.model.stop()
    }

    @Test func withoutTheCapabilityNothingHappens() async throws {
        var capabilities = Capabilities.fixture
        capabilities.canReact = false
        let harness = try await running(capabilities: capabilities)
        let before = try stored(harness)
        harness.model.react(to: harness.message.id, with: ReactionChoice(emoji: "🛞"), add: true)
        await settleAutoMarkRead()
        #expect(try stored(harness) == before)
        #expect(await harness.backend.commands
            .allSatisfy {
                if case .setReaction = $0 {
                    false
                } else {
                    true
                }
            })
        await harness.model.stop()
    }

    /// Review Focus 1: an optimistic message has no server id to react to.
    @Test func anUnsentMessageCannotBeReactedTo() async throws {
        let harness = try await running()
        let local = Message(
            id: Message.ID("local/l-1"), conversationID: harness.message.conversationID,
            threadID: MessageThread.ID(""), sender: Member.ID("u-1"), text: "x",
            createdAt: Date(timeIntervalSince1970: 2_000_000_000), localID: "l-1"
        )
        try harness.store.apply([.upsertMessage(local)])
        await settleAutoMarkRead()
        try #require(harness.model.messages.contains { $0.id == local.id })
        harness.model.react(to: local.id, with: ReactionChoice(emoji: "🛞"), add: true)
        await settleAutoMarkRead()
        #expect(await harness.backend.commands
            .allSatisfy {
                if case .setReaction = $0 {
                    false
                } else {
                    true
                }
            })
        await harness.model.stop()
    }
}
