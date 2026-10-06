import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import SyncEngine

/// `ChatSessionModel.me`, which session 9 slice 3 turned from an injected
/// constant into something watched from the store - the same shape
/// `conversations` and `connectionState` already had. `FakeBackend` is what
/// makes this testable without a live account: it now emits
/// `.selfIdentified` on `connect()` the same way a real bridge does, so this
/// suite exercises the one path both backends share rather than a fixture
/// only code path.
@Suite(.timeLimit(.minutes(1)))
struct ChatSessionModelTests {
    /// The store-driven value, arriving once `start()` has run the backend's
    /// `connect()` through to `SyncReducer`. `me: nil` at init is the case a
    /// real bridge is in: nothing is known synchronously, so this is the
    /// general path rather than the fixture's shortcut.
    @MainActor
    @Test func meIsObservedFromTheStoreOnceTheBackendIdentifiesItself() async throws {
        let backend = FakeBackend(world: .minimal)
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let model = ChatSessionModel(store: store, engine: engine, me: nil, markReadDebounce: .zero)

        try await model.start()

        for _ in 0 ..< 200 where model.me == nil {
            await Task.yield()
        }
        #expect(model.me == FixtureWorld.minimal.me)
        await model.stop()
    }

    /// The `me:` initialiser parameter is a starting value, not deleted: a
    /// backend that already knows its local user synchronously - `FakeBackend`
    /// today, via the world it was built with - should be able to render
    /// correctly before `start()` has reached the store at all.
    @MainActor
    @Test func meStartsAtTheInjectedValueBeforeStartIsCalled() throws {
        let backend = FakeBackend(world: .minimal)
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let model = ChatSessionModel(
            store: store,
            engine: engine,
            me: FixtureWorld.minimal.me,
            markReadDebounce: .zero
        )

        #expect(model.me == FixtureWorld.minimal.me)
    }

    /// The store-driven value replaces the injected one rather than fighting
    /// it: once `start()` runs, the observation's own read of the (still
    /// correct) store value lands on top of the starting value and agrees
    /// with it, rather than the two racing to different answers.
    @MainActor
    @Test func aStoreDrivenValueReplacesTheStartingValueWithoutDisagreeing() async throws {
        let backend = FakeBackend(world: .minimal)
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let model = ChatSessionModel(
            store: store,
            engine: engine,
            me: FixtureWorld.minimal.me,
            markReadDebounce: .zero
        )
        #expect(model.me == FixtureWorld.minimal.me)

        try await model.start()
        // Gives the watch a chance to deliver the store's own read, which
        // should confirm the starting value rather than contradict it.
        for _ in 0 ..< 200 {
            await Task.yield()
        }

        #expect(model.me == FixtureWorld.minimal.me)
        await model.stop()
    }
}

// MARK: - send(_:)

/// `send(_:)` pins two things a plausible tidy-up could quietly break: that
/// the optimistic row and the submitted command carry the same `localID`, and
/// that `if let me` gates only the optimistic write - not the submission
/// itself. Folding `me` into the top-level guard would look like a harmless
/// simplification and would instead drop every message sent in the window
/// right after connect but before the backend has said who "you" are, which
/// on a real bridge is the first thing that happens.
extension ChatSessionModelTests {
    /// The ordinary case: `me` is known, so `send` writes an optimistic row
    /// immediately (synchronously, inside `send` itself, before the network
    /// round trip starts) and then submits the command. Waiting for the
    /// backend's echo is how this test knows the command actually reached
    /// `FakeBackend` rather than merely being attempted - the echo carries the
    /// same `localID`, which is the thing this test exists to pin.
    @MainActor
    @Test func sendWritesTheOptimisticRowAndSubmitsWithTheSameLocalID() async throws {
        let backend = FakeBackend(world: .minimal)
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let model = ChatSessionModel(
            store: store,
            engine: engine,
            me: FixtureWorld.minimal.me,
            markReadDebounce: .zero
        )
        let conversation = Conversation.ID("dm:1")

        try await model.start()
        model.select(conversation)
        model.send(ComposedMessage(text: "hello from the composer"))

        // Synchronous: the optimistic write happens inside `send` itself,
        // before the submitting `Task` is even scheduled.
        let optimistic = try store.messages(in: conversation)
            .first { $0.id.rawValue.hasPrefix("local/") }
        let localID = try #require(optimistic?.localID)
        #expect(optimistic?.sender == FixtureWorld.minimal.me)
        #expect(optimistic?.text == "hello from the composer")

        // Asynchronous: wait for the backend's echo, which only arrives if
        // `engine.submit` actually reached `FakeBackend` and it accepted the
        // command.
        var echo: Message?
        for _ in 0 ..< 200 {
            echo = try store.messages(in: conversation)
                .first { $0.localID == localID && !$0.id.rawValue.hasPrefix("local/") }
            if echo != nil {
                break
            }
            await Task.yield()
        }
        #expect(try #require(echo).localID == localID)

        await model.stop()
    }

    /// `me == nil` is the state a real bridge starts every session in: nothing
    /// has told this client who it is yet. `send` must still reach the
    /// backend - only the optimistic echo-suppression row is what a missing
    /// `me` can't safely fabricate, because it would have to claim a sender it
    /// does not know.
    ///
    /// The backend here is deliberately never connected, so the same call
    /// that would otherwise submit the command instead fails at
    /// `requireConnected()` inside `FakeBackend` - and that refusal landing in
    /// `lastError` is the proof that `engine.submit` ran at all. If `send`
    /// silently returned instead (the bug this test guards against), no error
    /// would ever appear.
    @MainActor
    @Test func sendWithUnknownMeStillSubmitsWithoutAnOptimisticRow() async throws {
        let backend = FakeBackend(world: .minimal)
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let model = ChatSessionModel(store: store, engine: engine, me: nil, markReadDebounce: .zero)
        let conversation = Conversation.ID("dm:1")

        model.select(conversation)
        model.send(ComposedMessage(text: "hello before we know who we are"))

        // No optimistic row: nothing here knows who "you" are yet.
        let hasOptimisticRow = try store.messages(in: conversation)
            .contains { $0.id.rawValue.hasPrefix("local/") }
        #expect(!hasOptimisticRow)

        // The command still reached the backend, proven by its own refusal
        // landing in the store - the same path a real failure takes.
        var lastError: ChatError?
        for _ in 0 ..< 200 {
            lastError = try store.lastError()
            if lastError != nil {
                break
            }
            await Task.yield()
        }
        #expect(try #require(lastError) == .transport("not connected"))
    }

    /// A send that throws must not leave a message that looks delivered.
    ///
    /// The backend here is deliberately never connected, so `send` writes its
    /// optimistic row and the submission then throws - the same path a dead
    /// channel, a rejected `/api/` call, or a 30 s timeout takes. The row
    /// renders identically to a real message, `clearEphemeralState` does not
    /// touch `message`, so before this fix it survived relaunch and invited a
    /// re-send that - on a lost response to a POST that did land - posts the
    /// message twice in a real conversation.
    ///
    /// Both halves are asserted. The row being gone is the fix; the error
    /// still arriving is what stops the fix from becoming a silent swallow,
    /// which would be a different dishonest state rather than none.
    @MainActor
    @Test func aThrownSendRemovesTheOptimisticRowAndStillReportsTheError() async throws {
        let backend = FakeBackend(world: .minimal)
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let model = ChatSessionModel(
            store: store,
            engine: engine,
            me: FixtureWorld.minimal.me,
            markReadDebounce: .zero
        )
        let conversation = Conversation.ID("dm:1")

        model.select(conversation)
        model.send(ComposedMessage(text: "this one never leaves"))

        // Written synchronously inside `send`, before the submission that
        // fails is even scheduled - so the phantom genuinely exists first.
        #expect(try store.messages(in: conversation)
            .contains { $0.id.rawValue.hasPrefix("local/") })

        var lastError: ChatError?
        for _ in 0 ..< 200 {
            lastError = try store.lastError()
            if lastError != nil {
                break
            }
            await Task.yield()
        }
        #expect(try #require(lastError) == .transport("not connected"))
        // The phantom is gone. Asserted as "no local row" rather than "the
        // store is empty" because `select` fetched this conversation's real
        // history from the fixture on the way in, and that history is not
        // this test's business.
        let remaining = try store.messages(in: conversation)
        #expect(!remaining.contains { $0.id.rawValue.hasPrefix("local/") })
        #expect(!remaining.contains { $0.text == "this one never leaves" })
    }

    /// The echo beats the failure, and the delivered message survives.
    ///
    /// This is the `/api/` 30 s timeout where the POST actually landed: the
    /// long poll delivers the real message at about a second, `upsertMessage`
    /// replaces the optimistic row with it, and only then does `send` throw.
    /// The server echoes the client's `localID` back onto that real message,
    /// so a retraction keyed on `localID` deletes it - the user watches a
    /// genuine, posted message vanish beside a send-failed banner and re-sends
    /// it, which is the double post the retraction was written to prevent.
    ///
    /// Keying on the optimistic `Message.ID` makes the retraction a no-op
    /// here, because that row is already gone.
    ///
    /// The echo is applied to the store directly rather than emitted by a
    /// backend, so the ordering is fixed rather than raced: the optimistic
    /// write is synchronous inside `send`, and the submission that fails is
    /// still only a scheduled `Task` at this point.
    @MainActor
    @Test func anEchoThatArrivesBeforeTheFailureIsNotRetracted() async throws {
        let backend = FakeBackend(world: .minimal)
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let model = ChatSessionModel(
            store: store,
            engine: engine,
            me: FixtureWorld.minimal.me,
            markReadDebounce: .zero
        )
        let conversation = Conversation.ID("dm:1")

        model.select(conversation)
        model.send(ComposedMessage(text: "this one really did post"))

        let optimistic = try #require(
            try store.messages(in: conversation).first { $0.id.rawValue.hasPrefix("local/") }
        )
        let localID = try #require(optimistic.localID)
        // The echo: a real server id, the same localID, as
        // `ChannelEventMapping` builds it.
        try store.apply([.upsertMessage(Message(
            id: Message.ID("m-real"),
            conversationID: conversation,
            threadID: MessageThread.ID("t-1"),
            sender: FixtureWorld.minimal.me,
            text: "this one really did post",
            createdAt: Date(timeIntervalSince1970: 1000),
            localID: localID
        ))])

        var lastError: ChatError?
        for _ in 0 ..< 200 {
            lastError = try store.lastError()
            if lastError != nil {
                break
            }
            await Task.yield()
        }
        // The banner still appears - the send genuinely failed as far as this
        // client knows, and saying nothing would be its own dishonesty.
        #expect(try #require(lastError) == .transport("not connected"))
        // And the posted message is still there.
        let remaining = try store.messages(in: conversation)
        #expect(remaining.contains { $0.id.rawValue == "m-real" })
        #expect(!remaining.contains { $0.id.rawValue.hasPrefix("local/") })
    }

    /// Opening a conversation whose history will not load says so.
    ///
    /// `select` used to wrap the fetch in `try?`. The result was the failure
    /// shape session 13 §2.2 calls the worst kind: after a dead channel the
    /// transcript read "No messages", nothing had failed as far as the UI was
    /// concerned, and nothing was reported.
    ///
    /// Asserted on `model.lastError` rather than `store.lastError()`, because
    /// that is the value `ChatSceneState` hands the banner - so this covers
    /// the recording *and* the observation that carries it to the window.
    @MainActor
    @Test func openingAConversationWhoseHistoryFailsReportsIt() async throws {
        let backend = FailingBackend()
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let model = ChatSessionModel(store: store, engine: engine, markReadDebounce: .zero)

        try await model.start()
        model.select(Conversation.ID("space:1"))

        for _ in 0 ..< 500 where model.lastError == nil {
            await Task.yield()
        }
        #expect(model.lastError == .server(status: 500, message: "nope"))
        await model.stop()
    }

    /// The composer is already hidden when the backend cannot send, but
    /// `send` guards it too - defence in depth against a caller that reaches
    /// it anyway. Nothing is written and nothing is submitted: `lastError`
    /// staying `nil` is what tells the two apart, because a rejection coming
    /// back from `FakeBackend` itself (rather than `send`'s own guard) would
    /// also leave no optimistic row, but it would leave an error.
    @MainActor
    @Test func sendDoesNothingWhenTheBackendCannotSendMessages() async throws {
        let backend = FakeBackend(world: .minimal, capabilities: Capabilities(canSendMessages: false))
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let model = ChatSessionModel(
            store: store,
            engine: engine,
            me: FixtureWorld.minimal.me,
            markReadDebounce: .zero
        )
        let conversation = Conversation.ID("dm:1")

        try await model.start()
        model.select(conversation)
        model.send(ComposedMessage(text: "this should never leave the composer"))

        for _ in 0 ..< 50 {
            await Task.yield()
        }
        let messages = try store.messages(in: conversation)
        #expect(!messages.contains { $0.text == "this should never leave the composer" })
        #expect(try store.lastError() == nil)

        await model.stop()
    }
}
