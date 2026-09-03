import Foundation

/// The live event channel: `ChannelReducer` wired to a transport and a cookie
/// jar.
///
/// The split is the point. Every transition lives in the reducer, which is pure
/// and needs no network; this holds the things that cannot be pure — a socket,
/// a mutable credential, an event stream — and does as little deciding as
/// possible.
///
/// ## Cookie rotation is not optional
///
/// `findings.md` §12.3 measured 13 rotations in 100 seconds: the `*SIDCC`
/// family rotates on **every** poll cycle and `COMPASS` grew from 823 to 1029
/// characters on `register`. A transport replaying the captured header forever
/// is replaying a credential that went stale seconds after capture — which is
/// the most likely explanation for an early probe reporting a healthy handshake
/// and receiving no events at all.
///
/// So this absorbs `Set-Cookie` from every response, sends the *current* jar on
/// every request, and hands a snapshot back through `onRotation` only when
/// something actually changed. Only when: the store is on disk and rewriting an
/// unchanged session once per poll cycle is a write per second, forever.
///
/// ## Reconnecting - unbounded on purpose, since the reconnect taxonomy
///
/// It reconnects from every *recoverable* failure shape - via
/// `ChannelFailure.isRecoverable`: `.transport` unconditionally, because a
/// dead socket says nothing about whether the credential is still good, and
/// `.unexpectedStatus` at 400 (the reference's stale-SID signal, answered by
/// re-registering - what `.retry` already does here), 429 and every 5xx (on
/// HTTP semantics, not on traffic observed from Chat - see that property's own
/// doc comment). `.unexpectedStatus(401)`/`(403)`, `.noSessionIdentifier` and
/// `.malformedChunk` still stop and report why: a credential HTTP itself
/// rejects is not something a retry fixes, and the inputs that would tell a
/// *recovery* from a stop for the other two are recorded as uncollected in
/// §6.
///
/// **No longer bounded by an attempt count.** A four-consecutive-attempt
/// ceiling used to stop a recoverable failure outright; that ceiling was
/// itself the bug a live run reported - an outage longer than roughly eight
/// seconds was permanent until relaunch - so recoverable failures now retry
/// indefinitely instead. What still caps request pressure on a possibly-dead
/// account is the backoff: it climbs to `RetryPolicy`'s 32-second ceiling and
/// holds there, under two requests a minute, and the budget behind that climb
/// is cleared only by a body that ends cleanly - never by one that merely
/// opens. A channel that registers, handshakes, opens and then dies over and
/// over therefore keeps retrying at that capped rate rather than looping at
/// roughly five requests a second forever, which is the incident
/// `ChannelState.attempt`'s own doc comment records and the reason the reset
/// stays keyed to a clean close rather than to opening.
///
/// `.notConnectedToInternet` gets `.awaitNetwork` instead of the timer -
/// see the `.awaitNetwork` effect arm in `handle(_:)` below, which is a task-3
/// stopgap (identical to `.reconnect` today) until task 4 replaces it with a
/// real wait on `ReachabilityMonitor`.
public actor ChannelSession {
    /// The arrays as they arrive, in order.
    ///
    /// Unbounded on purpose: dropping an event here would silently desynchronise
    /// the client from the server's `aid` numbering, which is worse than memory
    /// pressure from a consumer that is briefly behind.
    public nonisolated let events: AsyncStream<ChannelArray>

    /// Why the channel stopped, if it did.
    public private(set) var failure: ChannelFailure?

    private let continuation: AsyncStream<ChannelArray>.Continuation
    private let transport: any HTTPTransport
    private let requests: ChannelRequests
    private let credentials: SessionCredentials

    private var state = ChannelState()
    private var pending: [ChannelEffect] = []
    private var task: Task<Void, Never>?
    private var requestIdentifier: Int
    private var generator = SystemRandomNumberGenerator()
    /// The backoff between reconnect attempts.
    ///
    /// **Only the delay comes from here, and there is no longer an attempt
    /// count to come from anywhere else.** `RetryPolicy.maxAttempts` is
    /// unused - the reducer's `ChannelState.failed(_:)` does not read it, or
    /// any bound, at all; a recoverable failure reconnects unconditionally.
    /// What this actually governs is how long each wait is, capped at the
    /// 32-second ceiling `RetryPolicy.default` itself defines.
    private let retry: RetryPolicy
    private let onLifecycle: (@Sendable (ChannelLifecycle) async -> Void)?
    /// Whether the last stream open followed a reconnect, so `.resumed` is sent
    /// once per recovery rather than on every reopen of a healthy channel.
    private var isRecovering = false

    /// - Parameter retry: The backoff between reconnect attempts. **Its
    /// `maxAttempts` is unused**: the reducer no longer bounds attempts at
    /// all, so a policy built with `maxAttempts: 10` behaves identically to
    /// one built with `maxAttempts: 4` - reconnecting is unconditional for a
    /// recoverable failure, and this only changes the *waiting* between
    /// attempts, which is what `.immediate` is for.
    public init(
        cookies: SessionCookies,
        transport: any HTTPTransport,
        endpoints: ChatEndpoints = ChatEndpoints(),
        retry: RetryPolicy = .default,
        onRotation: (@Sendable (SessionCookies) async -> Void)? = nil,
        onLifecycle: (@Sendable (ChannelLifecycle) async -> Void)? = nil
    ) {
        self.transport = transport
        self.retry = retry
        self.onLifecycle = onLifecycle
        credentials = SessionCredentials(cookies, onRotation: onRotation)
        requests = ChannelRequests(endpoints: endpoints)
        var generator = SystemRandomNumberGenerator()
        requestIdentifier = ChannelIdentifiers.initialRequestIdentifier(using: &generator)
        (events, continuation) = AsyncStream.makeStream(
            of: ChannelArray.self,
            bufferingPolicy: .unbounded
        )
    }

    /// Shares an existing credential rather than constructing one.
    ///
    /// This is what lets the `/api/` client and the channel put the *same*
    /// rotated cookies on their requests. Two jars for one session means the
    /// second is stale within seconds - §12.3 measured 13 rotations in 100
    /// seconds - and `onRotation` belongs to whoever owns the credential, which
    /// is why it is absent here.
    ///
    /// - Parameter retry: As above - the delay only. `maxAttempts` is unused;
    /// nothing bounds the attempt count any more.
    public init(
        credentials: SessionCredentials,
        transport: any HTTPTransport,
        endpoints: ChatEndpoints = ChatEndpoints(),
        retry: RetryPolicy = .default,
        onLifecycle: (@Sendable (ChannelLifecycle) async -> Void)? = nil
    ) {
        self.transport = transport
        self.credentials = credentials
        self.retry = retry
        self.onLifecycle = onLifecycle
        requests = ChannelRequests(endpoints: endpoints)
        var generator = SystemRandomNumberGenerator()
        requestIdentifier = ChannelIdentifiers.initialRequestIdentifier(using: &generator)
        (events, continuation) = AsyncStream.makeStream(
            of: ChannelArray.self,
            bufferingPolicy: .unbounded
        )
    }

    /// Opens the channel and runs it until it stops.
    ///
    /// Awaits the whole run rather than returning once connected: a caller that
    /// wants concurrency owns the `Task`, and hiding one in here would make the
    /// session's lifetime invisible to whoever has to cancel it.
    public func start() async {
        guard task == nil, case .idle = state.phase else { return }
        let task = Task { await run() }
        self.task = task
        await task.value
    }

    /// Stops the channel and finishes the event stream.
    public func stop() async {
        task?.cancel()
        apply(.disconnect)
        continuation.finish()
    }

    // MARK: - The loop

    private func run() async {
        apply(.connect)
        while !state.phase.isTerminal, !Task.isCancelled, !pending.isEmpty {
            await handle(pending.removeFirst())
        }
        continuation.finish()
    }

    /// Feeds the reducer and splits what comes back.
    ///
    /// Deliveries and reports happen **here**, synchronously, rather than being
    /// queued: an array queued behind a long poll would be delivered when that
    /// poll ends, which is minutes after it arrived. Only the effects that need
    /// the network are queued.
    private func apply(_ input: ChannelInput) {
        for effect in ChannelReducer.reduce(&state, input) {
            switch effect {
            case let .deliver(arrays):
                for array in arrays {
                    continuation.yield(array)
                }
            case let .report(reason):
                failure = reason
            case .finished:
                continue
            default:
                pending.append(effect)
            }
        }
    }

    private func handle(_ effect: ChannelEffect) async {
        switch effect {
        case .register:
            await send(requests.register()) { self.apply(.registered) }

        case .handshake:
            requestIdentifier += 1
            await openStream(
                requests.handshake(rid: requestIdentifier, zx: nextCacheBuster())
            )

        case let .acknowledge(sid, aid):
            // Fire-and-forget: the reference never inspects the response
            // (`channel.py:440-442`), and neither does anyone else know what it
            // is for beyond "it does seem to be required".
            await send(requests.acknowledge(sid: sid, aid: aid, zx: nextCacheBuster())) {}

        case let .reopen(sid, aid):
            await openStream(requests.reopen(sid: sid, aid: aid, zx: nextCacheBuster()))

        case let .reconnect(attempt):
            isRecovering = true
            await onLifecycle?(.reconnecting(attempt: attempt))
            // The wait lives here rather than in the reducer, which carries no
            // clock. `RetryPolicy` was written for exactly this and has been
            // dead code since it landed.
            try? await retry.waitBeforeRetry(attempt: attempt)
            guard !Task.isCancelled else { return }
            apply(.retry)

        case let .awaitNetwork(attempt):
            // Stopgap only: task 4 of the reconnect taxonomy replaces this with
            // a wait on `ReachabilityMonitor` (a bounded fallback timer if the
            // signal never comes), so the device offline case spends zero
            // requests instead of the timer this shares with `.reconnect`
            // today. Handled identically to `.reconnect` for now purely so this
            // switch stays exhaustive and the channel still recovers - not
            // because the two are policy-equivalent; `ChannelEffect
            // .awaitNetwork`'s own doc comment says why they are not.
            isRecovering = true
            await onLifecycle?(.reconnecting(attempt: attempt))
            try? await retry.waitBeforeRetry(attempt: attempt)
            guard !Task.isCancelled else { return }
            apply(.retry)

        case .deliver, .report, .finished:
            break // handled in apply(_:)
        }
    }

    private func send(_ request: HTTPRequest, then next: () -> Void) async {
        do {
            let request = await credentials.authorising(request)
            let response = try await transport.send(request)
            await absorb(response.headers)
            next()
        } catch let classified as ClassifiedTransportFailure {
            // `URLSessionTransport` has already classified this - see its own
            // doc comment on why `send`/`stream` do that rather than this
            // actor trying to, which would mean naming a networking type
            // `test.sh`'s portability scan forbids here.
            apply(.failed(.transport(classified.reason)))
        } catch {
            // Nothing above the transport boundary may call
            // `String(describing:)` on whatever it caught: this request
            // carries the long-poll's live SID, and that call is exactly how
            // one used to reach `ChannelFailure.description` and, from
            // there, a screen and `docs/protocol/findings.md`.
            apply(.failed(.transport(nil)))
        }
    }

    private func openStream(_ request: HTTPRequest) async {
        do {
            let request = await credentials.authorising(request)
            let stream = try await transport.stream(request)
            await absorb(stream.headers)
            apply(.streamOpened(
                status: stream.status,
                initialResponse: stream.headers["X-HTTP-Initial-Response"]
            ))
            if isRecovering, case .listening = state.phase {
                isRecovering = false
                // Cleared because it is no longer true, and a host reading it
                // after a recovery would report a session that is working as
                // one that failed.
                failure = nil
                await onLifecycle?(.resumed)
            }
            // The ack goes out before the body is read, not after it: the
            // reference sends it and then falls into the read loop, and a
            // client that acks afterwards has acked minutes late.
            await acknowledgeIfPending()
            guard !state.phase.isTerminal else { return }

            for try await data in stream.body {
                apply(.body(data))
                guard !state.phase.isTerminal else { return }
            }
            apply(.bodyEnded)
        } catch let classified as ClassifiedTransportFailure {
            // `URLSessionTransport` has already classified this - see its own
            // doc comment on why `send`/`stream` do that rather than this
            // actor trying to, which would mean naming a networking type
            // `test.sh`'s portability scan forbids here.
            apply(.failed(.transport(classified.reason)))
        } catch {
            // Nothing above the transport boundary may call
            // `String(describing:)` on whatever it caught: this request
            // carries the long-poll's live SID, and that call is exactly how
            // one used to reach `ChannelFailure.description` and, from
            // there, a screen and `docs/protocol/findings.md`.
            apply(.failed(.transport(nil)))
        }
    }

    /// Drains only the acknowledgement. Anything else queued here would be a
    /// new stream, and opening one while this body is still being read is how a
    /// channel ends up with two SIDs.
    private func acknowledgeIfPending() async {
        while let index = pending.firstIndex(where: {
            if case .acknowledge = $0 {
                return true
            }
            return false
        }) {
            await handle(pending.remove(at: index))
        }
    }

    // MARK: - Credentials

    private func absorb(_ headers: HTTPHeaders) async {
        await credentials.absorb(headers)
    }

    private func nextCacheBuster() -> String {
        ChannelIdentifiers.cacheBuster(using: &generator)
    }
}
