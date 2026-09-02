import ChatKit
import Foundation

/// A `ChatBackend` with no network, no credentials and no clock.
///
/// It serves a `FixtureWorld`, mutates it in response to `ChatCommand`s, and
/// emits the same `ChatEvent`s a real backend would. Two things drive it:
/// commands from a client through `send(_:)`, and `FixtureStep`s from a script
/// through `apply(_:)`, which is how a test plays the part of the server.
///
/// ## Determinism
///
/// Nothing here reads a wall clock or generates a random identifier. Time
/// starts at `world.startedAt` and moves forward by exactly `tick` whenever the
/// backend produces something; identifiers are a counter. Two backends given
/// the same world and the same input therefore emit byte-identical frames,
/// which `DeterminismTests` asserts by encoding them. That property is what
/// lets everything above the seam be tested without a golden file rotting every
/// time the suite runs a second later than it did before.
///
/// ## Waiting
///
/// This type never sleeps. `FixtureDemoDriver` is the only thing in the package
/// that does, and it is a separate type precisely so a test can play a script
/// instantly while the app plays the same script at human speed.
public actor FakeBackend {
    /// What this fake admits to being able to do, and what `send(_:)` enforces.
    public nonisolated let capabilities: Capabilities

    /// The event stream, built once here and **never finished**.
    ///
    /// `ChatBackend.events` requires one stream for the backend's lifetime that
    /// survives `disconnect()`. Making it a `let` created in `init` is how that
    /// is kept: there is no code path that could hand back a second stream or
    /// end this one, so no future edit reintroduces "the app stops updating
    /// after the network blips".
    ///
    /// Buffering is unbounded on purpose. A fake that dropped events under back
    /// pressure would manufacture upstream bugs that do not exist, and chasing
    /// one of those is a bad week.
    public nonisolated let events: AsyncStream<ChatEvent>

    /// Named rather than written inline so a test can assert on the exact
    /// reason without duplicating the string.
    public static let reconnectGapReason =
        "reconnected: a new session is not a continuation of the previous one"

    private let continuation: AsyncStream<ChatEvent>.Continuation

    /// How far `advance()` moves the clock each time the backend produces
    /// something.
    let tick: Duration

    /// How many messages `loadMessages(in:before:)` returns at most.
    let pageSize: Int

    var world: FixtureWorld
    var now: Date

    /// Counts everything yielded, so a test can wait for exactly as many events
    /// as were produced. See `emittedCount`.
    var emitted = 0
    var isConnected = false

    /// Distinguishes the first connection from a reconnection, which is the
    /// difference between a clean start and a gap.
    private var hasEverConnected = false

    /// Feeds every generated identifier, so `fixture-msg-3` means the third
    /// thing this backend made rather than the third message.
    private var sequence = 0

    public init(
        world: FixtureWorld = .minimal,
        capabilities: Capabilities = .fixture,
        tick: Duration = .seconds(1),
        pageSize: Int = 30
    ) {
        self.world = world
        self.capabilities = capabilities
        self.tick = tick
        self.pageSize = pageSize
        now = world.startedAt
        (events, continuation) = AsyncStream.makeStream(
            of: ChatEvent.self,
            bufferingPolicy: .unbounded
        )
    }
}

// MARK: - Lifecycle

public extension FakeBackend {
    /// Connects, and then says what the world is.
    ///
    /// The sequence is `connecting`, `connected`, then the snapshot: the
    /// conversation list, followed by one `membersChanged` per conversation.
    /// That last part is not padding. `Conversation.members` carries
    /// identifiers only - by design, so a membership change is not a fan-out -
    /// and something has to populate the store those identifiers point into
    /// before the first render.
    ///
    /// A **re**connect emits `gap(.everything)` before the snapshot, because a
    /// new session's stream is not a continuation of the old one's and a client
    /// that patched instead of reconciling would be quietly wrong. Making that
    /// path routine in the fake is the point: it is rare in production and
    /// therefore never exercised.
    ///
    /// Connecting while already connected does nothing at all.
    func connect() async throws {
        guard !isConnected else { return }
        isConnected = true

        emit(.connectionStateChanged(.connecting))
        emit(.connectionStateChanged(.connected))
        // The one path both backends share: `LocalBridgeBackend` emits this
        // from `get_self_user_status` after a real connect, and this is the
        // fixture's equivalent rather than a second, injected way of saying
        // who `me` is. `world.member(world.me)` is expected to resolve -
        // `FixtureWorld.inconsistencies()` flags a world where it would not -
        // but the fallback keeps this connect from crashing a test over a
        // fixture bug a different assertion already exists to catch.
        emit(.selfIdentified(world.member(world.me) ?? Member(id: world.me, kind: .human)))
        if hasEverConnected {
            emit(.gap(scope: .everything, reason: Self.reconnectGapReason))
        }
        hasEverConnected = true
        emitSnapshot()
    }

    /// Disconnects. The stream stays open; disconnection is an event, not the
    /// end of the conversation.
    func disconnect() async {
        guard isConnected else { return }
        isConnected = false
        emit(.connectionStateChanged(.disconnected(reason: nil)))
    }
}

// MARK: - Emission and bookkeeping

extension FakeBackend {
    func emit(_ event: ChatEvent) {
        emitted += 1
        continuation.yield(event)
    }

    /// The conversation list and the members of each conversation.
    func emitSnapshot() {
        emit(.conversationsChanged(world.conversations))
        for conversation in world.conversations {
            emit(
                .membersChanged(
                    conversationID: conversation.id,
                    members: world.members(in: conversation)
                )
            )
        }
    }

    /// Moves the clock on by one tick and returns the new instant. The only
    /// source of timestamps in this package.
    func advance() -> Date {
        now = now.addingTimeInterval(tick.seconds)
        return now
    }

    /// The next identifier with the given prefix. Deterministic, and shared
    /// across kinds so that no two identifiers can ever collide.
    func nextIdentifier(_ prefix: String) -> String {
        sequence += 1
        return "\(prefix)-\(sequence)"
    }

    /// Throws unless connected. `ChatBackend.send(_:)` promises to throw only
    /// when a command could not be *submitted*, and this is one of the two ways
    /// that happens.
    func requireConnected() throws {
        guard isConnected else { throw ChatError.transport("not connected") }
    }

    /// Throws unless the capability is advertised - the other way a command
    /// fails to be submitted. The name is the `Capabilities` property, so the
    /// error says exactly which flag to look at.
    func require(_ isAllowed: Bool, _ capability: String) throws {
        guard isAllowed else { throw ChatError.unsupported(capability: capability) }
    }
}

private extension Duration {
    /// `Duration` is a whole-and-attosecond pair; `Date` arithmetic wants
    /// seconds as a `Double`.
    var seconds: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
