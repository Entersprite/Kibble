import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import SyncEngine

/// `FakeBackend` -> `SyncEngine` -> database -> `ValueObservation`. The whole
/// stack above the seam, with no network, no account and no waiting.
///
/// This is also the second consumer of the fixture package, which is the point
/// of having built it: everything here would otherwise need a real Google
/// session.
@Suite(.timeLimit(.minutes(1)))
struct EndToEndTests {
    private let dm = Conversation.ID("dm:1")
    private let space = Conversation.ID("space:1")
    private let other = Member.ID("fixture-other")

    /// A started stack. A named type rather than a tuple because swiftlint
    /// caps tuples at two members, and three of these read better anyway.
    private struct Stack {
        let backend: FakeBackend
        let store: ChatStore
        let engine: SyncEngine
    }

    private func started() async throws -> Stack {
        let backend = FakeBackend(world: .minimal)
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        try await engine.start()
        return Stack(backend: backend, store: store, engine: engine)
    }

    /// Waits for the store to satisfy a condition.
    ///
    /// The engine consumes events on its own task, so a test cannot assert the
    /// instant after it sends one. Yielding alone is not quite enough - a
    /// yield does not guarantee another task makes progress if it is inside a
    /// database write - so this backs off to a short sleep, bounded at about
    /// two seconds. In practice every wait here settles in microseconds; the
    /// bound exists so a genuine hang fails by name instead of consuming the
    /// suite's time limit.
    private func eventually(
        _ description: String,
        _ condition: @Sendable () throws -> Bool
    ) async throws {
        for attempt in 0 ..< 2200 {
            if try condition() {
                return
            }
            if attempt < 200 {
                await Task.yield()
            } else {
                try await Task.sleep(for: .milliseconds(1))
            }
        }
        Issue.record("timed out waiting for: \(description)")
    }

    @Test func connectingFillsTheStoreWithTheWorld() async throws {
        let stack = try await started()
        let (store, engine) = (stack.store, stack.engine)

        try await eventually("conversations to land") { try store.conversations().count == 2 }
        #expect(try store.members().count == 2)
        // The connect snapshot carries membership, so the sidebar can render
        // names rather than identifiers on the first frame.
        #expect(try store.conversations().first?.members.isEmpty == false)
        #expect(try store.connectionState() == .connected)

        await engine.stop()
    }

    @Test func aLiveMessageReachesTheDatabase() async throws {
        let stack = try await started()
        let (backend, store, engine) = (stack.backend, stack.store, stack.engine)
        try await eventually("connect") { try store.conversations().count == 2 }

        try await backend.apply(
            .incomingMessage(conversation: dm, from: other, text: "you there?", thread: nil)
        )

        try await eventually("the message to land") { try store.messages(in: dm).count == 1 }
        #expect(try store.messages(in: dm).first?.text == "you there?")
        // The conversationUpdated that follows it carries the unread count.
        #expect(try store.conversations().first { $0.id == dm }?.unreadCount == 1)

        await engine.stop()
    }

    @Test func typingArrivesAndLeavesThroughTheStore() async throws {
        let stack = try await started()
        let (backend, store, engine) = (stack.backend, stack.store, stack.engine)

        try await backend.apply(.typing(conversation: dm, member: other, isTyping: true))
        try await eventually("typing on") { try store.typingMembers(in: dm) == [other] }

        try await backend.apply(.typing(conversation: dm, member: other, isTyping: false))
        try await eventually("typing off") { try store.typingMembers(in: dm).isEmpty }

        await engine.stop()
    }

    /// A gap says "whatever you believe may be wrong". Emptying the store first
    /// is how this test proves reconciliation actually happened rather than
    /// nothing having drifted.
    @Test func aWholeWorldGapReconcilesTheConversationList() async throws {
        let stack = try await started()
        let (backend, store, engine) = (stack.backend, stack.store, stack.engine)
        try await eventually("connect") { try store.conversations().count == 2 }

        try store.apply([.replaceConversations([])])
        #expect(try store.conversations().isEmpty)

        try await backend.apply(.gap(scope: .everything, reason: "buffer overflowed"))

        try await eventually("the list to come back") { try store.conversations().count == 2 }
        await engine.stop()
    }

    /// Connecting does not fetch history - that would be an unbounded read on
    /// every launch - so a conversation gap is what pulls a page in.
    @Test func aConversationGapFetchesThatConversationsMessages() async throws {
        let stack = try await started()
        let (backend, store, engine) = (stack.backend, stack.store, stack.engine)
        try await eventually("connect") { try store.conversations().count == 2 }
        #expect(try store.messages(in: space).isEmpty)

        try await backend.apply(.gap(scope: .conversation(space), reason: "catch-up aborted"))

        try await eventually("history to arrive") { try store.messages(in: space).count == 2 }
        await engine.stop()
    }

    @Test func historyIsFetchedOnDemandForAConversationTheUserOpens() async throws {
        let stack = try await started()
        let (store, engine) = (stack.store, stack.engine)
        try await eventually("connect") { try store.conversations().count == 2 }

        try await engine.loadMoreMessages(in: dm)

        #expect(try store.messages(in: dm).count == 2)
        await engine.stop()
    }

    @Test func aBackendErrorIsRecordedForTheUIToShow() async throws {
        let stack = try await started()
        let (backend, store, engine) = (stack.backend, stack.store, stack.engine)

        try await backend.apply(.error(.rateLimited(retryAfter: .seconds(30))))

        try await eventually("the error to land") {
            try store.lastError() == .rateLimited(retryAfter: .seconds(30))
        }
        await engine.stop()
    }

    /// The loop must outlive a failure. A backend that cannot answer is a
    /// Tuesday, not the end of the session.
    @Test func aFailedEffectIsRecordedAndTheLoopKeepsGoing() async throws {
        let backend = FailingBackend()
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        try await engine.start()

        await backend.emit(.gap(scope: .everything, reason: "reconnected"))
        try await eventually("the failure to be recorded") {
            try store.lastError() == .server(status: 500, message: "nope")
        }

        // Still consuming: this one has nothing to do with the failure.
        await backend.emit(.connectionStateChanged(.connected))
        try await eventually("the loop to still be alive") {
            try store.connectionState() == .connected
        }

        await engine.stop()
    }

    /// Restoring "Maya is typing" from three days ago would be a bug, not a
    /// cache hit.
    @Test func startingClearsWhatWasOnlyTrueLastTime() async throws {
        let backend = FakeBackend(world: .minimal)
        let store = try ChatStore.inMemory()
        try store.apply([
            .upsertMembers([Member(id: other, kind: .human, displayName: "Other")]),
            .setPresence(member: other, presence: .active),
            .setTyping(conversation: dm, member: other, isTyping: true)
        ])

        let engine = SyncEngine(backend: backend, store: store)
        try await engine.start()

        #expect(try store.typingMembers(in: dm).isEmpty)
        await engine.stop()
    }

    @Test func stoppingStopsConsuming() async throws {
        let stack = try await started()
        let (backend, store, engine) = (stack.backend, stack.store, stack.engine)
        try await eventually("connect") { try store.conversations().count == 2 }

        await engine.stop()
        try await backend.apply(
            .incomingMessage(conversation: dm, from: other, text: "too late", thread: nil)
        )

        // stop() waits for the consuming task to finish, so this is a settled
        // fact rather than a race.
        #expect(try store.messages(in: dm).isEmpty)
    }

    /// The whole point: a view iterates this and never learns a backend exists.
    @Test func aViewObservingTheStoreSeesLiveTraffic() async throws {
        let stack = try await started()
        let (backend, store, engine) = (stack.backend, stack.store, stack.engine)
        var iterator = store.observeMessages(in: dm).makeAsyncIterator()
        _ = try await iterator.next()

        try await backend.apply(
            .incomingMessage(conversation: dm, from: other, text: "live", thread: nil)
        )

        var seen: [Message] = []
        while seen.isEmpty {
            seen = try await iterator.next() ?? []
        }
        #expect(seen.map(\.text) == ["live"])
        await engine.stop()
    }
}
