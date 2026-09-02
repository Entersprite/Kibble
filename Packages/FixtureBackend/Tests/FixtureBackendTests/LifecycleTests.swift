import ChatKit
import Foundation
import Testing
@testable import FixtureBackend

/// The connection lifecycle, and the two `ChatBackend.events` contracts that a
/// client's whole update loop rests on.
@Suite(.timeLimit(.minutes(1)))
struct LifecycleTests {
    private let world = FixtureWorld.minimal

    @Test func connectAnnouncesItselfThenHandsOverTheWorld() async throws {
        let backend = FakeBackend(world: world)
        let collector = EventCollector(backend.events)

        try await backend.connect()

        let events = await collector.next(3 + world.conversations.count + 1)
        // #require rather than #expect: every assertion below indexes, and a
        // short array should fail this test by name, not trap and take the
        // whole run with it. Found by mutation-testing the stream contract.
        try #require(events.count == 3 + world.conversations.count + 1)
        #expect(events[0] == .connectionStateChanged(.connecting))
        #expect(events[1] == .connectionStateChanged(.connected))
        let me = try #require(world.member(world.me))
        #expect(events[2] == .selfIdentified(me))
        guard case let .conversationsChanged(list) = events[3] else {
            Issue.record("expected conversationsChanged, got \(events[3])")
            return
        }
        #expect(list == world.conversations)

        // One membersChanged per conversation: Conversation.members carries
        // identifiers only, so something has to fill the store they point into
        // before the first render, and connect is the only moment that can be.
        let membersEvents = events.dropFirst(4)
        #expect(membersEvents.count == world.conversations.count)
        for (event, conversation) in zip(membersEvents, world.conversations) {
            guard case let .membersChanged(conversationID, members) = event else {
                Issue.record("expected membersChanged, got \(event)")
                continue
            }
            #expect(conversationID == conversation.id)
            #expect(members == world.members(in: conversation))
        }
    }

    /// The load-bearing one. A client iterates `events` once at launch and must
    /// keep seeing events across every disconnect for the life of the process;
    /// a stream that finished on `disconnect()` would look like "the app stops
    /// updating after the network blips".
    @Test func oneStreamSurvivesDisconnectAndReconnect() async throws {
        let backend = FakeBackend(world: world)
        let collector = EventCollector(backend.events) // iterated once, here

        try await backend.connect()
        _ = await collector.next(6)

        await backend.disconnect()
        #expect(await collector.nextOne() == .connectionStateChanged(.disconnected(reason: nil)))

        try await backend.connect()
        let again = await collector.next(4)
        try #require(again.count == 4)
        #expect(again[0] == .connectionStateChanged(.connecting))
        #expect(again[1] == .connectionStateChanged(.connected))
        let me = try #require(world.member(world.me))
        #expect(again[2] == .selfIdentified(me))
        #expect(again[3] == .gap(scope: .everything, reason: FakeBackend.reconnectGapReason))
    }

    @Test func theSamePropertyHandsBackTheSameStream() async throws {
        let backend = FakeBackend(world: world)
        let first = EventCollector(backend.events)
        let second = backend.events

        try await backend.connect()

        // If `events` minted a fresh stream per access, `second` would be a
        // different channel and `first` would still be waiting.
        #expect(await first.nextOne() == .connectionStateChanged(.connecting))
        _ = second
    }

    /// Asserted without a timeout: if the second `connect()` emitted anything,
    /// the next event would not be the disconnection.
    @Test func connectingWhileConnectedEmitsNothing() async throws {
        let backend = FakeBackend(world: world)
        let collector = EventCollector(backend.events)

        try await backend.connect()
        _ = await collector.next(6)
        try await backend.connect()
        await backend.disconnect()

        #expect(await collector.nextOne() == .connectionStateChanged(.disconnected(reason: nil)))
    }

    @Test func disconnectingWhileDisconnectedEmitsNothing() async throws {
        let backend = FakeBackend(world: world)
        let collector = EventCollector(backend.events)

        await backend.disconnect()
        try await backend.connect()

        #expect(await collector.nextOne() == .connectionStateChanged(.connecting))
    }

    /// The first connect has nothing to invalidate; only a reconnect does.
    @Test func theFirstConnectDoesNotClaimAGap() async throws {
        let backend = FakeBackend(world: world)
        let collector = EventCollector(backend.events)

        try await backend.connect()

        let events = await collector.next(6)
        #expect(!events.contains {
            if case .gap = $0 {
                true
            } else {
                false
            }
        })
    }

    @Test func capabilitiesAreWhateverTheBackendWasBuiltWith() {
        #expect(FakeBackend(world: world).capabilities == .fixture)
        let degraded = Capabilities(canSendMessages: true)
        #expect(FakeBackend(world: world, capabilities: degraded).capabilities == degraded)
    }

    @Test func theFixtureCapabilitySetSaysYesToEverythingItKnowsAbout() {
        let capabilities = Capabilities.fixture
        #expect(capabilities.canSendMessages)
        #expect(capabilities.canEditMessages)
        #expect(capabilities.canDeleteMessages)
        #expect(capabilities.canReact)
        #expect(capabilities.canSendTypingState)
        #expect(capabilities.receivesTypingState)
        #expect(capabilities.receivesReadReceipts)
        #expect(capabilities.canSetNotificationLevel)
        #expect(capabilities.canMarkRead)
        #expect(capabilities.supportsThreads)
        #expect(capabilities.supportsHistoryCatchUp)
    }
}
