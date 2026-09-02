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

    /// Why a freshly connected session reports a gap. For logs only - a client
    /// must never branch on a gap's reason, because the set of reasons is open.
    static let connectedGapReason = "connected: nothing is known about this session yet"

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
    public nonisolated let capabilities = Capabilities(canSendMessages: true, supportsThreads: true)

    public nonisolated let events: AsyncStream<ChatEvent>

    /// The last failure, for a host that wants to report more than the stream
    /// carries. The event stream remains the supported channel.
    public private(set) var lastFailure: ChatError?

    private let continuation: AsyncStream<ChatEvent>.Continuation
    private let cookies: SessionCookies
    private let endpoints: ChatEndpoints
    private let transport: any HTTPTransport
    private let bootstrap: Bootstrap
    /// Shared with `ChannelSession`, which is the entire reason this exists as
    /// a hoisted actor rather than a value each caller copies: two jars for one
    /// session means the second is stale within seconds (`findings.md` §12.3).
    private let credentials: SessionCredentials
    /// Handed to every `ChannelSession` this backend opens. Always `.default`
    /// outside tests - see the internal initialiser.
    private let channelRetry: RetryPolicy
    private var isConnected = false
    private var channel: ChannelSession?
    private var channelTask: Task<Void, Never>?

    /// The `/api/` client, built once `connect()` has a verified session and
    /// an xsrf token. `nil` before that - `loadConversations()` reads this
    /// rather than the raw pieces, so "not connected yet" is one check instead
    /// of two.
    /// Not `private`: `LocalBridgeBackend+SelfIdentification.swift` reads it
    /// too, the same reason `emit(_:)` below is not `private` either.
    var apiClient: ProtoAPIClient?

    /// The in-flight name lookup, if any. Held so `disconnect()` can cancel it
    /// and so a second `loadConversations()` supersedes the first rather than
    /// racing it to emit `membersChanged` for a world that has moved on.
    private var memberResolution: Task<Void, Never>?

    /// The in-flight `get_self_user_status` call, if any. Same shape as
    /// `memberResolution` and cancelled in `disconnect()` for the same reason:
    /// a session that has moved on must not have a stale identity land after
    /// it.
    private var selfIdentification: Task<Void, Never>?

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
    /// It exists because the default policy is four attempts over seven and a
    /// half real seconds, and a scripted transport always runs out - so without
    /// it every test that waits for a channel to finish waits out the whole
    /// ladder.
    init(
        cookies: SessionCookies,
        transport: any HTTPTransport,
        endpoints: ChatEndpoints = ChatEndpoints(),
        retry: RetryPolicy,
        onRotation: (@Sendable (SessionCookies) async -> Void)? = nil
    ) {
        self.cookies = cookies
        self.endpoints = endpoints
        self.transport = transport
        channelRetry = retry
        credentials = SessionCredentials(cookies, onRotation: onRotation)
        bootstrap = Bootstrap(transport: transport)
        (events, continuation) = AsyncStream.makeStream(
            of: ChatEvent.self,
            bufferingPolicy: .unbounded
        )
    }

    /// Whether the long poll is running. For tests and for a host that wants to
    /// show more than the last event said.
    public var isRunningChannel: Bool {
        channelTask != nil
    }

    /// Waits for the channel to stop. Tests use it; nothing in the app should,
    /// because it returns when the session ends.
    public func waitForChannel() async {
        await channelTask?.value
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
            emit(.connectionStateChanged(.disconnected(reason: Self.reason(for: chatError))))
            emit(.backendError(chatError))
            throw chatError
        }
    }

    public func disconnect() async {
        guard isConnected else { return }
        isConnected = false
        apiClient = nil
        memberResolution?.cancel()
        memberResolution = nil
        selfIdentification?.cancel()
        selfIdentification = nil
        await stopChannel()
        emit(.connectionStateChanged(.disconnected(reason: nil)))
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
            }
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
        for chatEvent in ChannelEventMapping.chatEvents(from: event) {
            emit(chatEvent)
        }
    }

    /// The channel's own recovery, forwarded as connection state.
    ///
    /// `ConnectionState.reconnecting(attempt:)` has existed in `ChatKit` since
    /// the seam was written and has been emitted by nobody. It is what lets a
    /// window say "attempt 2" instead of spinning silently, and it needs no
    /// wire-format change to reach a hosted tier later.
    private func channelLifecycleChanged(_ event: ChannelLifecycle) {
        switch event {
        case let .reconnecting(attempt):
            emit(.connectionStateChanged(.reconnecting(attempt: attempt)))
        case .resumed:
            lastFailure = nil
            emit(.connectionStateChanged(.connected))
        }
    }

    /// The channel reconnects only from a dead socket, and only four times, so
    /// it still ends - and its ending is news. Saying nothing would leave a
    /// window showing a healthy session that has quietly stopped delivering.
    ///
    /// The guard is on **identity**, not merely on there being a channel. A
    /// `disconnect()` → `connect()` sequence leaves the old task still
    /// unwinding, and its `channelStopped` arriving after the new channel is
    /// running would tear down the *new* session - `channelTask`, `channel`,
    /// `isConnected` and `apiClient` all nilled for a channel that is
    /// perfectly alive, presenting as a session that connects and instantly
    /// reports itself disconnected. Unreachable from the app as it stands,
    /// because nothing reconnects; latent, and the fix is one clause.
    /// Internal rather than private only so a test can hand it a channel that
    /// is not the current one, which is the whole condition being guarded and
    /// is otherwise a race no test could schedule. Same reason
    /// `isRunningChannel` and `waitForChannel()` exist.
    func channelStopped(_ channel: ChannelSession) async {
        // `channelTask == nil` is a deliberate disconnect; a channel that is
        // not the current one is a straggler from a previous session.
        guard channel === self.channel, channelTask != nil else { return }
        channelTask = nil
        self.channel = nil
        isConnected = false
        apiClient = nil
        let failure = await channel.failure
        let reason = failure.map(String.init(describing:)) ?? "the channel closed"
        if let failure {
            let error = ChatError.transport(String(describing: failure))
            lastFailure = error
            emit(.backendError(error))
        }
        emit(.connectionStateChanged(.disconnected(reason: reason)))
    }

    /// The conversation list, via the one request shape `findings.md` §20.1
    /// proved works: `request_header` + `fetch_from_user_spaces` + one
    /// `WorldSectionRequest(page_size: 999)` - `WorldRequestLadder.minimumViable`.
    ///
    /// **Requires `connect()` to have already succeeded.** Without it there is
    /// no verified session and no xsrf token, and sending a `/api/` request
    /// with neither would not be a real attempt - it would be a request known
    /// in advance to fail, dressed up as one that tried.
    public func loadConversations() async throws -> [Conversation] {
        guard let apiClient else {
            throw ChatError.unknown(
                "loadConversations() requires connect() to succeed first - "
                    + "there is no verified session or xsrf token yet"
            )
        }
        let rung = WorldRequestLadder.minimumViable
        do {
            let response = try await apiClient.call(.paginatedWorld, rung.request)
            let mapped = WorldMapping.map(response)
            // `ChatBackend.loadConversations()` returns `[Conversation]` and
            // cannot carry `.skipped` alongside it, but silently returning a
            // shorter array is exactly the kind of loss `WorldMapping.Result`
            // exists to prevent - a count, never an id or a name, reaches the
            // store the UI observes instead of vanishing between two layers
            // that each assumed the other reported it.
            if mapped.skipped > 0 {
                emit(.backendError(.unknown(
                    "\(mapped.skipped) conversation(s) could not be mapped and were skipped"
                )))
            }
            // **Started, not awaited.** `SyncEngine` writes the conversations
            // to the store only once this returns, so awaiting the name lookup
            // would hold the entire sidebar behind it - and `get_members` has
            // never been sent by this implementation, carries a 30-second
            // timeout, and is exactly the wrong call to bet a first render on.
            //
            // Names arrive afterwards as `membersChanged`, which the store
            // already reduces and the views already observe. Ids first and
            // names a moment later is what the observation path is for; an
            // empty sidebar for thirty seconds is not.
            //
            // It also cannot throw by construction, so a failed name lookup can
            // never be mistaken for the world call failing and turn a degraded
            // sidebar into an empty one - the bug this package's own history
            // records as "exactly what an empty sidebar and no error message
            // looked like".
            memberResolution?.cancel()
            memberResolution = Task { [weak self] in
                await self?.resolveAndEmitMembers(for: mapped.conversations, using: apiClient)
            }
            return mapped.conversations
        } catch {
            throw Self.chatError(fromAPI: error)
        }
    }

    func emit(_ event: ChatEvent) {
        continuation.yield(event)
    }
}
