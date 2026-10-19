import ChatKit
import Foundation
import GChatBridgeCore

/// Google protocol translation for one verified account. Network, credential
/// storage, proof computation and optional reachability are injected by its host.
/// Client code uses ChatBackend; provider/session objects stay behind that seam.
public actor LocalBridgeBackend: ChatBackend {
    /// The capability name every unimplemented action reports.
    ///
    /// One name, because they are all blocked on the same missing thing, and a
    /// caller that logs it learns something true.
    public static let missingChannel = "liveChannel"

    // `capabilities` lives in `LocalBridgeBackend+Capabilities.swift` - a
    // computed property, moved out once search's own additions pushed this
    // file to `file_length`.

    public nonisolated let events: AsyncStream<ChatEvent>

    /// The last failure, for a host that wants to report more than the stream
    /// carries. The event stream remains the supported channel.
    ///
    /// `internal(set)`, not `private(set)`: `channelStopped(_:)`
    /// (`LocalBridgeBackend+ChannelStopped.swift`) sets it too.
    public internal(set) var lastFailure: ChatError?

    let continuation: AsyncStream<ChatEvent>.Continuation
    private let cookies: SessionCookies
    /// `internal`, not `private`: `+People.swift` sends the people search.
    nonisolated let diagnostics: ProviderDiagnostics
    nonisolated let proof: ProviderProof
    let endpoints: ChatEndpoints
    /// `internal` for the same reason.
    let transport: any HTTPTransport
    private let bootstrap: Bootstrap
    /// Shared with `ChannelSession`, which is the entire reason this exists as
    /// a hoisted actor rather than a value each caller copies: two jars for one
    /// session means the second is stale within seconds (`findings.md` §12.3).
    let credentials: SessionCredentials
    /// Handed to every `ChannelSession` this backend opens. Always `.default`
    /// outside tests - see the internal initialiser.
    private let channelRetry: RetryPolicy
    /// Optional host-supplied recovery hints; nil retains the bounded timer.
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
    /// Built beside `apiClient` and cleared with it (`+Uploads.swift`).
    var attachmentUpload: AttachmentUpload?
    /// What each upload this session made answered, by token, so a send
    /// returns it verbatim (`uploadAnnotations(_:uploaded:)`). Cleared by
    /// `connect()` and `disconnect()`. An upload still in flight across a
    /// disconnect writes its entry afterwards; that is harmless, because a
    /// token names one upload and a send only looks up the ones it carries.
    var uploadedMetadata: [String: UploadMetadata] = [:]

    /// The in-flight name lookup, if any. Held so `disconnect()` can cancel it
    /// and so a second `loadConversations()` supersedes the first rather than
    /// racing it to emit `membersChanged` for a world that has moved on.
    /// Not `private`: the presence poll waits for it (`startPresencePoll`).
    var memberResolution: Task<Void, Never>?
    var meetingMetadata = MeetingMetadataHydration()
    var meetingMetadataCacheFile: MeetingMetadataCacheFile?
    var meetingMetadataNow: @Sendable () -> Date = { Date() }

    /// Every member id this session has asked `get_members` about, or is
    /// asking about now, so a sender who appears on every page is looked up
    /// once. Not `private`: `LocalBridgeBackend+Directory.swift` owns the
    /// lookups. Cleared by `disconnect()`.
    var requestedMemberIDs: Set<ChatKit.Member.ID> = []

    /// Bumped by `disconnect()`, so an on-demand lookup that answers
    /// afterwards can tell its session has gone. A counter, not a held task:
    /// those lookups are many and short.
    var receiptRevisions: [Conversation.ID: Int] = [:]
    var directoryGeneration = 0
    var discoverableManagementSpaces: Set<Conversation.ID> = []
    var managementOperations: [String: ManagementOperation] = [:]

    /// Email by member id, from every `get_members` answer this session, for
    /// the `invitee_info` a sent mention carries (`findings.md` §56.2). Never
    /// sent anywhere else, and cleared with the directory.
    var memberEmails: [ChatKit.Member.ID: String] = [:]

    /// The bootstrap's WIZ blob, for the people search's key. Cleared by
    /// `disconnect()`.
    var bootstrapWiz: WizGlobalData?

    /// The people search's key and its one fetch (`+People.swift`).
    var peopleKey = PeopleKeyState()

    /// The in-flight `get_self_user_status` call, if any. Same shape as
    /// `memberResolution` and cancelled in `disconnect()` for the same reason:
    /// a session that has moved on must not have a stale identity land after
    /// it.
    var selfIdentification: Task<Void, Never>?

    /// The presence poll's state (`LocalBridgeBackend+Presence.swift`), and
    /// how often it asks: `defaultPresencePollInterval` outside tests.
    var presencePoll = PresencePoll()
    /// The calendar poll's state (`LocalBridgeBackend+Calendar.swift`).
    var calendarPoll = CalendarPoll()
    /// `--probe=events`' tally (`LocalBridgeBackend+EventTally.swift`); `nil` otherwise.
    var eventTally: EventTallyFile?
    let presencePollInterval: Duration
    /// Coalesced `list_messages` refetches triggered by `MESSAGE_REACTED`
    /// (`LocalBridgeBackend+ReactionRefetch.swift`).
    var reactionRefetches = ReactionRefetches()
    /// How long a refetch waits before asking: `defaultReactionRefetchDelay`
    /// outside tests.
    let reactionRefetchDelay: Duration
    /// `SBNmJb`'s `_reqid` counter (`LocalBridgeBackend+Search.swift`),
    /// mirroring the probe's own `SearchCallContext.nextRequestID()`. Not
    /// reset by `disconnect()`: a fresh base per process is all §65.6 says it
    /// needs to be - a monotonically increasing value, never repeated.
    var searchRequestID = Int.random(in: 1000 ... 9999)
    /// Each mapped message's create time, for anchored history
    /// (`MessageCreateTimes`, `findings.md` §65.9). Cleared by `disconnect()`.
    var messageTimes = MessageCreateTimes()
    /// The world's newest top-level message per conversation. A plain
    /// `list_topics` page can end before this head, leaving an unread dot
    /// without the message the client needs to mark read.
    var conversationHeads: [Conversation.ID: Int64] = [:]
    var historyCutoffs: [Conversation.ID: Int64] = [:]
    var hiddenConversations: Set<Conversation.ID> = []
    var hiddenThrough: [Conversation.ID: Int64] = [:]
    var onConversationAction: (@Sendable (ConversationActionObservation) -> Void)?
    var conversationDetails: [Conversation.ID: WorldItemLite] = [:]
    /// Host-owned, content-free telemetry for failed read-state writes.
    var onReadStateFailure: (@Sendable (ReadStateRequestFailure) -> Void)?
    var onHistoryResponse: (@Sendable (HistoryResponseObservation) -> Void)?

    public init(
        cookies: SessionCookies,
        transport: any HTTPTransport,
        endpoints: ChatEndpoints = ChatEndpoints(),
        onRotation: (@Sendable (SessionCookies) async -> Void)? = nil,
        proof: ProviderProof = .portable,
        diagnostics: ProviderDiagnostics = .init()
    ) {
        self.init(
            cookies: cookies,
            transport: transport,
            endpoints: endpoints,
            retry: .default,
            onRotation: onRotation, proof: proof, diagnostics: diagnostics
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
        reactionRefetchDelay: Duration = defaultReactionRefetchDelay,
        proof: ProviderProof = .portable,
        diagnostics: ProviderDiagnostics = .init()
    ) {
        self.proof = proof
        self.diagnostics = diagnostics
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
            bootstrapWiz = wiz
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
            attachmentUpload = AttachmentUpload(
                transport: transport, endpoints: endpoints, credentials: credentials, xsrfToken: wiz.xsrfToken
            )
            uploadedMetadata = [:]
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
        bootstrapWiz = nil
        apiClient = nil
        attachmentFetch = nil
        attachmentUpload = nil
        uploadedMetadata = [:]
        messageTimes.forgetAll()
        conversationHeads = [:]
        conversationDetails = [:]
        hiddenConversations = []
        hiddenThrough = [:]
        historyCutoffs = [:]
        memberResolution?.cancel()
        memberResolution = nil
        forgetDirectory()
        forgetReactionRefetches()
        selfIdentification?.cancel()
        selfIdentification = nil
        stopPolls()
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
        messageTimes.remember(chatEvents.flatMap(Self.messages(in:)))
        for (body, chatEvent) in zip(event.bodies, chatEvents) {
            reconcileHiddenConversation(chatEvent, type: body.typeTag)
            emit(chatEvent)
        }
        resolveUnknownMembers(chatEvents.flatMap(Self.memberIDs(in:)))
    }
}
