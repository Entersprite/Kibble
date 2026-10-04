import ChatKit
import Foundation
import GChatBridgeCore

/// The in-process bridge: `GChatBridgeCore` hosted inside the app.
///
/// **Incomplete on purpose, and explicit about it.** Today it can do exactly one
/// thing - verify that a captured session still authenticates - because that is
/// what the core can do today. `ChannelSession` does not exist yet, so there is
/// no event channel, no history and no sending, and every one of those methods
/// says so by name rather than failing vaguely.
///
/// It exists now rather than later because it answers a standing question from
/// the architecture design: whether the reverse-engineered core embeds cleanly
/// in a Swift macOS app target, in-process, with no bridging pain. It does, and
/// this package is the proof - it is also the only package in the repo that
/// imports the core, which is what keeps a future iOS binary free of it.
public actor LocalBridgeBackend: ChatBackend {
    /// The capability name every unimplemented action reports.
    ///
    /// One name, because they are all blocked on the same missing thing, and a
    /// caller that logs it learns something true.
    public static let missingChannel = "liveChannel"

    /// Almost nothing is advertised until it works.
    ///
    /// Not modesty - the UI reads `capabilities` to decide what to offer, and a
    /// bridge claiming it could do something it could not would hand the user a
    /// composer that silently swallowed their messages. `canSendMessages` is
    /// now true: `send(_:)` posts through `create_topic` /
    /// `create_message` (`LocalBridgeBackend+Send.swift`), `[Verify]` until a
    /// deliberate single send against live traffic confirms the shape.
    /// `supportsThreads` is the other exception: `loadConversations()` now maps
    /// `isThreaded` for real (`WorldMapping`), so a client can tell a flat
    /// group from a threaded one without guessing.
    /// `canMarkRead` is now true: `.markRead` posts through
    /// `mark_group_readstate` (`LocalBridgeBackend+ReadState.swift`) and the
    /// response's own `GroupReadState` becomes `.readStateChanged`.
    /// `[Verify]` until one deliberate call against live traffic confirms the
    /// shape. `receivesReadReceipts` stays false and is a different claim -
    /// it is about *other people's* read positions, which nothing here maps.
    /// `canDownloadFiles` is backed by `findings.md` §52.10's live download.
    /// `canReact` is true: `.setReaction` posts through `update_reaction`
    /// (`LocalBridgeBackend+Reactions.swift`), `[Verify]` until a live toggle
    /// confirms the shape.
    /// `canFetchCustomEmoji` is true on `findings.md` §54.4's capture: the
    /// image call is the one Chat on the web makes, `[Verify]` from here.
    public nonisolated let capabilities = Capabilities(
        canSendMessages: true, canReact: true, canMarkRead: true, supportsThreads: true,
        canFetchAttachments: true, canDownloadFiles: true, canFetchCustomEmoji: true
    )

    public nonisolated let events: AsyncStream<ChatEvent>

    /// The last failure, for a host that wants to report more than the stream
    /// carries. The event stream remains the supported channel.
    ///
    /// `internal(set)`, not `private(set)`: `channelStopped(_:)`
    /// (`LocalBridgeBackend+ChannelStopped.swift`) sets it too.
    public internal(set) var lastFailure: ChatError?

    private let continuation: AsyncStream<ChatEvent>.Continuation
    private let cookies: SessionCookies
    private let endpoints: ChatEndpoints
    private let transport: any HTTPTransport
    private let bootstrap: Bootstrap
    /// Shared with `ChannelSession`, which is the entire reason this exists as
    /// a hoisted actor rather than a value each caller copies: two jars for one
    /// session means the second is stale within seconds (`findings.md` §12.3).
    let credentials: SessionCredentials
    /// Handed to every `ChannelSession` this backend opens. Always `.default`
    /// outside tests - see the internal initialiser.
    private let channelRetry: RetryPolicy
    /// Handed to every `ChannelSession` this backend opens, the same as
    /// `channelRetry`. `nil` is a legitimate value everywhere - `ChannelSession`
    /// itself degrades to its bounded fallback timer when there is no monitor -
    /// so every existing call site keeps compiling unchanged. `SessionHandoff
    /// .swift`'s `using(_:transport:)` is the one place this defaults to a real
    /// `NWPathReachabilityMonitor`; every other entry point, including the
    /// public initialiser below, leaves it `nil`.
    ///
    /// Not `private`, for the same reason `isConnected`, `channel` and
    /// `channelTask` below are not: `private` blocks even `@testable import`
    /// from another file in this target, and there would otherwise be no way
    /// for a test to assert that the public `using(_:transport:)` call site
    /// - the one `SystemLaunchServices` actually uses - produces a backend
    /// carrying a real, non-nil monitor. `SessionHandoffTests
    /// .theRealUsingOverloadSuppliesARealReachabilityMonitor` is that test;
    /// without this relaxation, a future edit reverting that default to `nil`
    /// would compile cleanly and every test would still pass while the whole
    /// feature went silently inert.
    let channelReachability: (any ReachabilityMonitor)?
    /// Not `private`: `LocalBridgeBackend+ChannelStopped.swift` reads and
    /// writes it too, the same reason `apiClient` and `emit(_:)` are not
    /// `private` either.
    var isConnected = false
    /// Not `private`: `channelStopped(_:)` (`LocalBridgeBackend+ChannelStopped.swift`)
    /// takes a channel to compare by identity against this one.
    var channel: ChannelSession?
    /// Not `private`: `channelStopped(_:)`'s guard reads this, and clears it,
    /// from `LocalBridgeBackend+ChannelStopped.swift`.
    var channelTask: Task<Void, Never>?

    /// The `/api/` client, built once `connect()` has a verified session and
    /// an xsrf token. `nil` before that - `loadConversations()` reads this
    /// rather than the raw pieces, so "not connected yet" is one check instead
    /// of two.
    /// Not `private`: `LocalBridgeBackend+SelfIdentification.swift` reads it
    /// too, the same reason `emit(_:)` below is not `private` either.
    var apiClient: ProtoAPIClient?
    /// Built beside `apiClient` and cleared with it (`+Attachments.swift`).
    var attachmentFetch: AttachmentFetch?

    /// The in-flight name lookup, if any. Held so `disconnect()` can cancel it
    /// and so a second `loadConversations()` supersedes the first rather than
    /// racing it to emit `membersChanged` for a world that has moved on.
    /// Not `private`: the presence poll waits for it (`startPresencePoll`).
    var memberResolution: Task<Void, Never>?

    /// Every member id this session has asked `get_members` about, or is
    /// asking about now, so a sender who appears on every page is looked up
    /// once. Not `private`: `LocalBridgeBackend+Directory.swift` owns the
    /// lookups. Cleared by `disconnect()`.
    var requestedMemberIDs: Set<ChatKit.Member.ID> = []

    /// Bumped by `disconnect()`, so an on-demand lookup that answers
    /// afterwards can tell its session has gone. A counter, not a held task:
    /// those lookups are many and short.
    var directoryGeneration = 0

    /// The in-flight `get_self_user_status` call, if any. Same shape as
    /// `memberResolution` and cancelled in `disconnect()` for the same reason:
    /// a session that has moved on must not have a stale identity land after
    /// it.
    private var selfIdentification: Task<Void, Never>?

    /// The presence poll's state (`LocalBridgeBackend+Presence.swift`), and
    /// how often it asks: `defaultPresencePollInterval` outside tests.
    var presencePoll = PresencePoll()
    /// `--probe=events`' tally (`LocalBridgeBackend+EventTally.swift`); `nil` otherwise.
    var eventTally: EventTallyFile?
    let presencePollInterval: Duration
    /// Coalesced `list_messages` refetches triggered by `MESSAGE_REACTED`
    /// (`LocalBridgeBackend+ReactionRefetch.swift`).
    var reactionRefetches = ReactionRefetches()
    /// How long a refetch waits before asking: `defaultReactionRefetchDelay`
    /// outside tests.
    let reactionRefetchDelay: Duration

    public init(
        cookies: SessionCookies,
        transport: any HTTPTransport,
        endpoints: ChatEndpoints = ChatEndpoints(),
        onRotation: (@Sendable (SessionCookies) async -> Void)? = nil
    ) {
        self.init(
            cookies: cookies,
            transport: transport,
            endpoints: endpoints,
            retry: .default,
            onRotation: onRotation
        )
    }

    /// The same thing, plus the channel's reconnect backoff.
    ///
    /// **Internal, and it has to stay internal.** `RetryPolicy` is a
    /// `GChatBridgeCore` type, and a public parameter would put a core type in
    /// this package's app-facing surface - the containment `CLAUDE.md` keeps so
    /// that a future iOS binary carries no protocol code. Tests reach it
    /// through `@testable import`; the app cannot see it at all, and the public
    /// initialiser above is unchanged.
    ///
    /// It exists because, without `.immediate`, a channel that keeps failing
    /// waits out `RetryPolicy.default`'s real backoff before every retry. That
    /// wait used to be bounded - four attempts, about seven and a half real
    /// seconds, then the channel gave up. Since task 3 of the reconnect
    /// taxonomy it no longer gives up on its own, so the wait a test would
    /// otherwise sit through is unbounded rather than 7.5 seconds.
    /// `.immediate` removes it, which is what every test that waits for a
    /// channel to finish needs.
    /// - Parameter reachability: The device's network-reachability signal, if
    /// the caller has one. Forwarded verbatim to every `ChannelSession` this
    /// backend opens; see `ChannelSession`'s own doc comment on why `nil`
    /// degrades rather than fails.
    /// - Parameter presencePollInterval: Shortened by tests only.
    /// - Parameter reactionRefetchDelay: Shortened by tests only.
    init(
        cookies: SessionCookies,
        transport: any HTTPTransport,
        endpoints: ChatEndpoints = ChatEndpoints(),
        retry: RetryPolicy,
        onRotation: (@Sendable (SessionCookies) async -> Void)? = nil,
        reachability: (any ReachabilityMonitor)? = nil,
        presencePollInterval: Duration = defaultPresencePollInterval,
        reactionRefetchDelay: Duration = defaultReactionRefetchDelay
    ) {
        self.cookies = cookies
        self.endpoints = endpoints
        self.transport = transport
        channelRetry = retry
        channelReachability = reachability
        self.presencePollInterval = presencePollInterval
        self.reactionRefetchDelay = reactionRefetchDelay
        credentials = SessionCredentials(cookies, onRotation: onRotation)
        bootstrap = Bootstrap(transport: transport)
        (events, continuation) = AsyncStream.makeStream(
            of: ChatEvent.self,
            bufferingPolicy: .unbounded
        )
    }

    /// Verifies the session, and stops there.
    ///
    /// Failures are **both thrown and emitted**. Thrown because `connect()`
    /// promises to report an attempt that failed outright; emitted because a UI
    /// reads the store and would otherwise never learn why nothing is syncing.
    public func connect() async throws {
        guard !isConnected else { return }
        emit(.connectionStateChanged(.connecting))
        do {
            let wiz = try await bootstrap.run(cookies: cookies, endpoints: endpoints)
            guard wiz.isSignedIn else {
                throw ChatError.notAuthenticated
            }
            isConnected = true
            lastFailure = nil
            // The xsrf token `connect()` used to discard - every `/api/` call
            // needs it, and it only ever comes from a fresh bootstrap.
            apiClient = ProtoAPIClient(
                transport: transport,
                endpoints: endpoints,
                credentials: credentials,
                xsrfToken: wiz.xsrfToken
            )
            attachmentFetch = AttachmentFetch(
                transport: transport, endpoints: endpoints, credentials: credentials, xsrfToken: wiz.xsrfToken
            )
            emit(.connectionStateChanged(.connected))
            // **Started, not awaited**, the same rule `loadConversations()`
            // follows for `resolveAndEmitMembers` and for the same reason:
            // `connect()` must not hold the whole launch behind one `/api/`
            // call. A failure here is a degraded title, not a broken
            // session - `resolveAndEmitSelf()` turns it into a
            // `.backendError` and nothing stronger.
            selfIdentification?.cancel()
            selfIdentification = Task { [weak self] in
                await self?.resolveAndEmitSelf()
            }
            // **Nothing else asks for the world.** `SyncEngine` reaches
            // `loadConversations()` only through the `.reloadConversations`
            // effect, and `SyncReducer` produces that only for
            // `gap(scope: .everything)`. Without this the conversation list is
            // implemented, correct, and never called - which is exactly what
            // an empty sidebar and no error message looked like.
            //
            // A gap rather than a pushed snapshot, because that is what this is:
            // `ChatEvent.gap`'s own contract is "whatever the client believes
            // about this scope may be wrong, reconcile from scratch", and a
            // client that has just connected believes nothing. It also keeps
            // the pull in one place instead of having `connect()` do I/O the
            // reducer already owns.
            emit(.gap(scope: .everything, reason: Self.connectedGapReason))
            startChannel()
        } catch {
            let chatError = Self.chatError(from: error)
            lastFailure = chatError
            emit(.connectionStateChanged(.disconnected(
                reason: Self.reason(for: chatError),
                issue: ConnectionIssueMapping.issue(forConnect: error)
            )))
            emit(.backendError(chatError))
            throw chatError
        }
    }

    public func disconnect() async {
        guard isConnected else { return }
        isConnected = false
        apiClient = nil
        attachmentFetch = nil
        memberResolution?.cancel()
        memberResolution = nil
        forgetDirectory()
        forgetReactionRefetches()
        selfIdentification?.cancel()
        selfIdentification = nil
        stopPresencePoll()
        await stopChannel()
        emit(.connectionStateChanged(.disconnected(reason: nil, issue: nil)))
    }

    /// Opens the long poll and pumps it into the domain.
    ///
    /// Started rather than awaited: `connect()` promises a verified session, not
    /// a finished one, and a long poll ends when the account signs out. A caller
    /// blocked on that would never return.
    private func startChannel() {
        guard channelTask == nil else { return }
        // Shares this backend's own `credentials` rather than constructing a
        // second jar - two jars for one session means the second is stale
        // within seconds (`findings.md` §12.3), and it is what lets the
        // channel and `apiClient` put the *same* rotated cookies on their
        // requests.
        let channel = ChannelSession(
            credentials: credentials,
            transport: transport,
            endpoints: endpoints,
            retry: channelRetry,
            onLifecycle: { [weak self] event in
                await self?.channelLifecycleChanged(event)
            },
            reachability: channelReachability
        )
        self.channel = channel
        channelTask = Task { [weak self] in
            // Consuming and running are separate tasks because `start()` runs
            // until the channel stops, and events have to be delivered while it
            // does rather than afterwards.
            async let running: Void = channel.start()
            for await array in channel.events {
                await self?.deliver(array)
            }
            await running
            await self?.channelStopped(channel)
        }
    }

    private func stopChannel() async {
        let task = channelTask
        channelTask = nil
        await channel?.stop()
        channel = nil
        task?.cancel()
    }

    /// One delivered array, translated and emitted.
    ///
    /// `ChannelEventMapping` returns one domain event per body and never drops
    /// one, so a type this bridge does not understand still reaches the store as
    /// `.unknown` rather than disappearing between two layers that each assumed
    /// the other handled it.
    private func deliver(_ array: ChannelArray) {
        guard let event = ChannelEvent(array) else { return }
        recordInTally(event)
        for body in event.bodies {
            if let reacted = ChannelEventMapping.reactedMessage(in: body) {
                requestReactionRefetch(reacted)
            }
        }
        let chatEvents = ChannelEventMapping.chatEvents(from: event)
        for chatEvent in chatEvents {
            emit(chatEvent)
        }
        resolveUnknownMembers(chatEvents.flatMap(Self.memberIDs(in:)))
    }

    func emit(_ event: ChatEvent) {
        continuation.yield(event)
    }
}
