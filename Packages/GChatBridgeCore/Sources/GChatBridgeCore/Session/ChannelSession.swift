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
/// ## What this deliberately does not do
///
/// It does not reconnect. A failure stops the channel and reports why, because
/// the inputs a recovery policy would be built from are recorded as uncollected
/// in §6 — and a policy written against the reference's guesses is work that
/// gets thrown away when the evidence arrives.
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

    public init(
        cookies: SessionCookies,
        transport: any HTTPTransport,
        endpoints: ChatEndpoints = ChatEndpoints(),
        onRotation: (@Sendable (SessionCookies) async -> Void)? = nil
    ) {
        self.transport = transport
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
    public init(
        credentials: SessionCredentials,
        transport: any HTTPTransport,
        endpoints: ChatEndpoints = ChatEndpoints()
    ) {
        self.transport = transport
        self.credentials = credentials
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
        } catch {
            apply(.failed(.transport(String(describing: error))))
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
        } catch {
            apply(.failed(.transport(String(describing: error))))
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
