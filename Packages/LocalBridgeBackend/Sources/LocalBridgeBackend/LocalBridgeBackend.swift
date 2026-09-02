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
    /// Not modesty - the UI reads `capabilities` to decide what to offer, so a
    /// bridge claiming it could send would hand the user a composer that
    /// silently swallowed their messages. `supportsThreads` is the one
    /// exception: `loadConversations()` now maps `isThreaded` for real
    /// (`WorldMapping`), so a client can tell a flat group from a threaded one
    /// without guessing.
    public nonisolated let capabilities = Capabilities(supportsThreads: true)

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
    private var isConnected = false
    private var channel: ChannelSession?
    private var channelTask: Task<Void, Never>?

    /// The `/api/` client, built once `connect()` has a verified session and
    /// an xsrf token. `nil` before that - `loadConversations()` reads this
    /// rather than the raw pieces, so "not connected yet" is one check instead
    /// of two.
    private var apiClient: ProtoAPIClient?

    public init(
        cookies: SessionCookies,
        transport: any HTTPTransport,
        endpoints: ChatEndpoints = ChatEndpoints(),
        onRotation: (@Sendable (SessionCookies) async -> Void)? = nil
    ) {
        self.cookies = cookies
        self.endpoints = endpoints
        self.transport = transport
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
            endpoints: endpoints
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

    /// The channel does not reconnect - it reports and stops - so its ending is
    /// news, and saying nothing would leave a window showing a healthy session
    /// that has quietly stopped delivering.
    private func channelStopped(_ channel: ChannelSession) async {
        guard channelTask != nil else { return } // a deliberate disconnect
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

    public func send(_: ChatCommand) async throws {
        throw ChatError.unsupported(capability: Self.missingChannel)
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
            return mapped.conversations
        } catch {
            throw Self.chatError(fromAPI: error)
        }
    }

    /// `ChatKit.Message`, spelled out.
    ///
    /// This is the one package that imports both the domain and the generated
    /// protobuf, and the protobuf has a `Message` of its own. Every domain type
    /// whose name the wire also uses has to be qualified here - which is a real
    /// cost of hosting the core, and an argument for keeping this package thin.
    public func loadMessages(
        in _: Conversation.ID,
        before _: ChatKit.Message.ID?
    ) async throws -> [ChatKit.Message] {
        throw ChatError.unsupported(capability: Self.missingChannel)
    }

    public func setNotificationSetting(
        _: NotificationLevel,
        for _: Conversation.ID
    ) async throws {
        throw ChatError.unsupported(capability: Self.missingChannel)
    }

    private func emit(_ event: ChatEvent) {
        continuation.yield(event)
    }
}

// MARK: - Translating the core's failures

extension LocalBridgeBackend {
    /// Maps a bootstrap failure onto the domain's error vocabulary.
    ///
    /// The distinctions are the point. A previous session spent three cookie
    /// captures on what turned out to be a rejected *client*, because every
    /// failure on this protocol arrives as HTTP 200 and the diagnosis had been
    /// flattened to "your credentials are bad".
    static func chatError(from error: any Error) -> ChatError {
        if let error = error as? ChatError {
            return error
        }
        guard let failure = error as? BootstrapFailure else {
            return .transport(String(describing: error))
        }
        switch failure {
        case .signInRedirect:
            return .notAuthenticated
        case let .unsupportedClient(url):
            // Not a credentials problem: the session authenticated and the
            // client was refused. Naming the browser is what stops the next
            // person re-capturing cookies that were fine.
            return .transport("Chat rejected this client as an unsupported browser (\(url.path))")
        case let .unexpectedStatus(status):
            return .server(status: status, message: "the Chat shell")
        case let .noGlobalData(diagnosis):
            // Carries no page content - the diagnosis is counts, a status and a
            // capped title, which is deliberate, because a signed-in shell has
            // real names and messages in it.
            return .unknown(String(describing: diagnosis))
        }
    }

    static func reason(for error: ChatError) -> String {
        switch error {
        case .notAuthenticated, .sessionExpired: "not signed in"
        default: "could not reach Chat"
        }
    }

    /// Maps an `/api/` call's failure onto the domain's error vocabulary.
    ///
    /// **There is deliberately no `.notAuthenticated` case here**, mirroring
    /// `APIFailure`'s own doc comment: whether `/api/` answers a dead session
    /// the way the Chat shell does (HTTP 200 plus a sign-in page, per §13) is
    /// unrecorded - no run has put an expired credential in front of it.
    /// Guessing either way would promote a guess to a policy.
    static func chatError(fromAPI error: any Error) -> ChatError {
        guard let failure = error as? APIFailure else {
            return .transport(String(describing: error))
        }
        switch failure {
        case let .httpStatus(status):
            return .server(status: status, message: "the /api/ paginated_world call")
        case .transport:
            return .transport(failure.safeDescription)
        case .emptyBody, .undecodable:
            return .decoding(failure.safeDescription)
        }
    }
}
