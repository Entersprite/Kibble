import Foundation

/// Why a channel stopped.
///
/// Two of these four are unconditionally terminal. The inputs that would tell
/// a *recovery* apart from a stop for them — a cookie expiring mid-stream, a
/// truncated payload — are recorded as uncollected in `findings.md` §6, and the
/// experiment that collects them is one someone has to run against a real
/// account over days. Writing a reconnect policy against the reference's
/// guesses and rewriting it when the evidence lands is more work than waiting,
/// so `.noSessionIdentifier` and `.malformedChunk` stop and say why.
///
/// `.transport` recovers unconditionally: a socket that died says nothing
/// about whether the credential is still good, so re-registering is right
/// whatever §6 eventually finds.
///
/// `.unexpectedStatus` recovers **only for the literal value 400**, not "any
/// 4xx" or "any non-200". `reference/googlechat-master/maugclib/channel.py:
/// 408-411` raises `SIDInvalidError` when a long poll answers 400 with
/// `Unknown SID`. `exceptions.py:27-34` makes `SIDInvalidError` and
/// `SIDExpiringError` *siblings* under `SIDError`, not parent and child, so
/// `listen`'s `except SIDExpiringError` clause (`channel.py:233-239`, which
/// re-registers in place) does not catch it — the 400 propagates out of
/// `listen` and the reference rebuilds the channel from a fresh `_register()`,
/// which is exactly what this side's `.retry` transition already does. A 2026-
/// 09-02 lid-close (app open, screen locked, lid closed two minutes, lid
/// opened) produced exactly this: HTTP 400, no other status observed before
/// or since. `[Verify]`: the response body was not read, so "Unknown SID" is
/// the probable cause by mechanism, not a confirmed one. A 401 or 403
/// plausibly means the credential itself is dead, and retrying those is the
/// hammering this bound exists to prevent — see `isRecoverable` and
/// `ChannelState.failed(_:)`.
public enum ChannelFailure: Error, Hashable, Sendable, CustomStringConvertible {
    case unexpectedStatus(Int)
    case noSessionIdentifier
    case malformedChunk(String)
    /// A classification, not a raw description - this request carries the
    /// long-poll's live SID, so `String(describing:)` on an unclassified
    /// `URLError` was a leak. `nil` means `ChannelSession` caught something
    /// that did not classify as a `ClassifiedTransportFailure`.
    case transport(TransportFailureReason?)

    public var description: String {
        switch self {
        case let .unexpectedStatus(status):
            "the channel answered with HTTP \(status)"
        case .noSessionIdentifier:
            "the handshake carried no SID"
        case let .malformedChunk(detail):
            "a chunk could not be read: \(detail)"
        case let .transport(reason):
            "the connection failed: \(reason?.safeDescription ?? "transport error")"
        }
    }

    /// Whether `ChannelState.failed(_:)` should ask to reconnect, bounded by
    /// `RetryPolicy.default.maxAttempts`, rather than stopping outright.
    ///
    /// Exactly `.transport` and `.unexpectedStatus(400)` — see the type's own
    /// doc comment for why each earns it and why 400 alone, not every 4xx.
    var isRecoverable: Bool {
        switch self {
        case .transport, .unexpectedStatus(400):
            true
        case .unexpectedStatus, .noSessionIdentifier, .malformedChunk:
            false
        }
    }
}

/// Where the channel is.
public enum ChannelPhase: Sendable, Hashable {
    case idle
    case registering
    case handshaking
    /// The long poll is open and delivering.
    case listening(sid: String)
    /// The previous poll ended and a new one has been asked for. Ordinary: the
    /// poll closes on its own within seconds of the handshake (§3.5).
    case reopening(sid: String)
    /// The socket died and a fresh registration has been asked for. `attempt`
    /// counts from 1, matching `ChatKit.ConnectionState.reconnecting(attempt:)`
    /// so a host can forward the number without re-basing it.
    case reconnecting(attempt: Int)
    case failed(ChannelFailure)
    case closed

    public var isFailed: Bool {
        if case .failed = self {
            return true
        }
        return false
    }

    /// Whether the machine will still respond to anything.
    var isTerminal: Bool {
        switch self {
        case .failed, .closed: true
        default: false
        }
    }

    var sid: String? {
        switch self {
        case let .listening(sid), let .reopening(sid): sid
        default: nil
        }
    }
}

/// Something that happened.
///
/// Facts, not resources: the driver reads the socket and reports what it saw,
/// so this side needs no network, no clock and no randomness.
public enum ChannelInput: Sendable {
    case connect
    /// `register` completed. Its body is not inspected — the reference does not
    /// either, and what it is actually for is the rotated `COMPASS`.
    case registered
    /// A long-poll response's *head* arrived. `initialResponse` is the
    /// `X-HTTP-Initial-Response` header, which is where a SID comes from.
    case streamOpened(status: Int, initialResponse: String?)
    /// A raw read off the socket. Not a chunk: boundaries are this machine's
    /// problem.
    case body(Data)
    /// The response body ended. Ordinary, not an error.
    case bodyEnded
    case failed(ChannelFailure)
    /// The driver has waited out the backoff and is ready to start again.
    /// Separate from `.connect` because `connect()` is single-flight from
    /// `.idle` and a reconnect is not starting from nothing - it is resuming
    /// from a known-dead socket.
    case retry
    case disconnect
}

/// What the driver should do next.
///
/// **Intents rather than built requests.** A `.reopen` becomes a URL with a
/// fresh cache-buster in the driver, which keeps this side free of randomness
/// and leaves `ChannelRequests` the only place a URL is spelled out.
public enum ChannelEffect: Sendable, Hashable {
    case register
    case handshake
    case acknowledge(sid: String, aid: Int)
    case reopen(sid: String, aid: Int)
    /// Wait, then send `.retry`. The delay lives in the driver: this side
    /// carries no clock and no randomness, which is `ChannelInput`'s stated
    /// contract and the reason the reducer is testable without waiting.
    case reconnect(attempt: Int)
    case deliver([ChannelArray])
    case report(ChannelFailure)
    case finished
}

/// The channel's state.
public struct ChannelState: Sendable {
    public fileprivate(set) var phase: ChannelPhase = .idle

    /// The highest array handed to the consumer, and therefore what the next
    /// reopen sends as `AID`.
    ///
    /// It advances when arrays are delivered rather than when they are
    /// received, which is the reference's rule and the safe direction: an `AID`
    /// that is too low costs a resend, one that is too high loses events
    /// silently.
    public fileprivate(set) var highestProcessedAid = 0

    /// Consecutive failed connection attempts.
    ///
    /// Reset by a body that **ends cleanly**, not by one that merely opens.
    /// The difference is the whole bound. A stream that opens is only a
    /// promise; a stream that ends the way §3.5 says a healthy poll ends -
    /// within seconds, on its own - is proof the channel worked. Resetting on
    /// the promise made the ladder unbounded for the one failure that matters:
    /// register + handshake reach HTTP 200 with a SID, the body then dies
    /// rather than ending, and every cycle cleared the budget it had just
    /// spent. That is ~5 requests a second against a real account, forever,
    /// and a middlebox, a VPN or a machine that sleeps and wakes all produce
    /// it.
    ///
    /// A healthy channel still never exhausts its budget, because it reaches
    /// `bodyEnded` every few seconds. One that drops once an hour resets on
    /// the first clean close after each recovery. One that never closes
    /// cleanly stops after four.
    public fileprivate(set) var attempt = 0

    /// Framing state for the *current* stream. Reset on every reopen: a partial
    /// chunk belongs to the body it started in, and prepending it to the next
    /// one would desynchronise the framing from there on.
    private var parser = ChunkParser()

    public init() {}
}

/// The channel's state machine.
///
/// `(Input) -> (State, [Effect])`, the shape session 1 §9 specified for this
/// component and `SyncReducer` already uses — so the repo has one pattern
/// rather than two, and a future bridge server can run this reduction rather
/// than a second one written to match it.
public enum ChannelReducer {
    public static func reduce(_ state: inout ChannelState, _ input: ChannelInput) -> [ChannelEffect] {
        // A stopped channel stays stopped. Answering inputs after failing would
        // keep a dead session looking alive, and the driver's in-flight reads
        // do not all stop the instant it decides to.
        guard !state.phase.isTerminal else { return [] }

        switch input {
        case .disconnect:
            state.stop(.closed)
            return [.finished]

        case let .failed(failure):
            return state.failed(failure)

        case .retry:
            return state.retry()

        case .connect:
            return state.connect()

        case .registered:
            return state.registered()

        case let .streamOpened(status, initialResponse):
            return state.streamOpened(status: status, initialResponse: initialResponse)

        case let .body(data):
            return state.received(data)

        case .bodyEnded:
            return state.bodyEnded()
        }
    }
}

// MARK: - Transitions

private extension ChannelState {
    mutating func stop(_ phase: ChannelPhase) {
        self.phase = phase
        parser = ChunkParser()
    }

    mutating func reopen(sid: String) {
        phase = .reopening(sid: sid)
        parser = ChunkParser()
    }

    /// A stream that actually opened.
    ///
    /// Deliberately does **not** clear `attempt`. A stream that opens has
    /// proved only that register and handshake answered; the body can still
    /// die a millisecond later, and clearing the budget here meant that
    /// failure mode retried without limit. `bodyEnded()` is where the budget
    /// is earned back - see `ChannelState.attempt`.
    mutating func listen(sid: String) {
        phase = .listening(sid: sid)
    }

    /// Single-flight. Two SIDs on one account is a way to have events delivered
    /// to the one nobody is reading.
    mutating func connect() -> [ChannelEffect] {
        guard case .idle = phase else { return [] }
        phase = .registering
        return [.register]
    }

    mutating func registered() -> [ChannelEffect] {
        guard case .registering = phase else { return [] }
        phase = .handshaking
        return [.handshake]
    }

    /// The end of a body is ordinary: the poll closes on its own within seconds
    /// of the handshake (§3.5). A client that read it as a failure would see one
    /// handshake and conclude nothing was arriving.
    ///
    /// It is also the only evidence the channel is genuinely working, so this
    /// is where the retry budget is cleared. See `ChannelState.attempt`.
    mutating func bodyEnded() -> [ChannelEffect] {
        guard let sid = phase.sid else { return [] }
        attempt = 0
        reopen(sid: sid)
        return [.reopen(sid: sid, aid: highestProcessedAid)]
    }

    mutating func streamOpened(status: Int, initialResponse: String?) -> [ChannelEffect] {
        // Routed through `failed(_:)` rather than stopped directly: a
        // handshake or reopen answering with an unexpected status is where
        // `.unexpectedStatus` actually originates in production (`ChannelSession
        // .openStream` feeds every stream response through `.streamOpened`,
        // never through a raw `.failed(.unexpectedStatus(_))` input), so this
        // is the one place that must honour `isRecoverable` for a 400 to
        // reconnect rather than merely being classified recoverable in theory.
        guard status == 200 else {
            return failed(.unexpectedStatus(status))
        }

        // A reopen usually carries no new SID and simply continues.
        guard let initialResponse else {
            guard case let .reopening(sid) = phase else {
                // A handshake that answered 200 and named no session. On this
                // protocol a failure is routinely a 200, so the status was
                // never the thing to read.
                stop(.failed(.noSessionIdentifier))
                return [.report(.noSessionIdentifier), .finished]
            }
            listen(sid: sid)
            return []
        }

        let sid: String
        do {
            sid = try ChannelChunk.sid(inInitialResponse: initialResponse)
        } catch {
            stop(.failed(.noSessionIdentifier))
            return [.report(.noSessionIdentifier), .finished]
        }

        // An unchanged SID on a reopen is just the stream continuing.
        if phase.sid == sid {
            listen(sid: sid)
            return []
        }

        // A new session numbers its arrays from scratch; carrying the old
        // watermark over would ask it to skip past events it has not sent.
        highestProcessedAid = 0
        listen(sid: sid)
        return [.acknowledge(sid: sid, aid: 0)]
    }

    mutating func received(_ data: Data) -> [ChannelEffect] {
        guard case .listening = phase else { return [] }

        let payloads: [String]
        do {
            payloads = try parser.chunks(from: data)
        } catch {
            return fail(.malformedChunk(String(describing: error)))
        }
        guard !payloads.isEmpty else { return [] }

        var arrays: [ChannelArray] = []
        for payload in payloads {
            do {
                arrays += try ChannelChunk.arrays(in: payload)
            } catch {
                return fail(.malformedChunk(String(describing: error)))
            }
        }
        guard !arrays.isEmpty else { return [] }

        // Never backwards. An out-of-order or repeated array must not lower the
        // watermark, or the next reopen asks for what has already been handled.
        highestProcessedAid = max(highestProcessedAid, arrays.map(\.aid).max() ?? 0)
        return [.deliver(arrays)]
    }

    mutating func fail(_ failure: ChannelFailure) -> [ChannelEffect] {
        stop(.failed(failure))
        return [.report(failure), .finished]
    }

    /// Only the two `isRecoverable` classes reconnect: `.transport`
    /// unconditionally, `.unexpectedStatus` only at the literal value 400.
    ///
    /// Session 8 §1.4 deferred reconnect because the inputs to a recovery
    /// policy - `400 Unknown SID`, a cookie expiring mid-stream, a truncated
    /// payload - were uncollected in `findings.md` §6, and a policy written
    /// against the reference's guesses gets discarded when the evidence lands.
    /// That objection is about *classification*. It still stands for
    /// `.noSessionIdentifier` and `.malformedChunk`. It never applied to a
    /// transport failure, which says nothing about the credential either way.
    /// And 400 has since been collected (see `ChannelFailure`'s doc comment):
    /// the reference's own reaction to it is a full re-registration, which is
    /// what `.retry` already does here, so classifying it recoverable adds no
    /// new machinery.
    ///
    /// Both recoverable classes share one budget - `attempt` does not reset
    /// between them - because the bound exists to cap total hammering of a
    /// possibly-dead account, not to give each failure shape its own quota.
    mutating func failed(_ failure: ChannelFailure) -> [ChannelEffect] {
        guard failure.isRecoverable, attempt < RetryPolicy.default.maxAttempts else {
            return fail(failure)
        }
        attempt += 1
        phase = .reconnecting(attempt: attempt)
        parser = ChunkParser()
        return [.reconnect(attempt: attempt)]
    }

    mutating func retry() -> [ChannelEffect] {
        guard case .reconnecting = phase else { return [] }
        phase = .registering
        return [.register]
    }
}
