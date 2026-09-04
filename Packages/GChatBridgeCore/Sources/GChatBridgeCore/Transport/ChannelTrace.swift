import Foundation

/// One long-poll stream's transport-level behaviour, recorded as it happens.
///
/// Declared here and implemented outside - the same division `HTTPTransport`
/// and `ReachabilityMonitor` already use, and for the same reason: this
/// protocol is the whole surface `URLSessionTransport.stream()` needs, and it
/// takes nothing but durations, counts and short strings, so nothing about a
/// concrete conformance - a file, a socket, a Darwin API - has to be true here
/// for `GChatBridgeCore` to keep compiling on Linux. `nil` is the default
/// everywhere this is threaded, and a `nil` sink costs `stream()` one pointer
/// check per byte and nothing else - see its own doc comment.
///
/// **This exists to answer one question the project could not answer from
/// userspace**: whether incoming messages are delayed by a server that is not
/// pushing promptly, or by the URL loading system withholding bytes it has
/// already received (`findings.md` §12.4, never isolated until now). Every
/// method here is aimed at that question and nothing else - it is diagnostic
/// instrumentation, not a feature, and it must never change what the channel
/// does, only what gets written down about what it already did.
///
/// **Never a URL, a cookie, a token, or message content.** A conformance may
/// be handed a `Content-Type` value and a byte count; it must never be handed,
/// and this protocol never carries, anything that could identify a session -
/// the same rule `LoginTrace` and `TransportFailureReason` already keep, now
/// applied at the one boundary that sees every byte of the live long poll.
public protocol ChannelTraceSink: Sendable {
    /// A stream is being opened - `kind` is `"handshake"` for the first long
    /// poll after a fresh SID and `"reopen"` for every poll after, matching
    /// `ChannelRequests.handshake(rid:zx:)` / `.reopen(sid:aid:zx:)` via
    /// `HTTPRequest.traceLabel`. `"unlabeled"` means a caller opened a stream
    /// through this transport without going through `ChannelRequests` at all -
    /// worth noticing, not worth failing over.
    ///
    /// `instant` is a `ContinuousClock` reading, taken immediately before the
    /// request is handed off for sending, so it is immune to a sleep/wake
    /// cycle corrupting the interval to the next event - see this file's own
    /// header for why a wall clock was rejected for every timestamp here.
    func streamOpened(kind: String, at instant: ContinuousClock.Instant)

    /// The response head arrived. `status` and all three header values are
    /// exactly what the server sent - `nil` for a header that was absent,
    /// which is itself the finding for `Content-Encoding`/`Transfer-Encoding`,
    /// not a gap in the recording.
    ///
    /// **`contentType` is the single most decisive field this whole
    /// instrument exists to capture.** `application/json` or
    /// `application/octet-stream` rules out the URL-loading-system-buffering
    /// hypothesis on the spot; anything else leaves it standing.
    func responseHeadReceived(
        status: Int,
        contentType: String?,
        contentEncoding: String?,
        transferEncoding: String?,
        at instant: ContinuousClock.Instant
    )

    /// One byte-arrival batch closed - see `ChannelTraceBatcher` for how a run
    /// of near-simultaneous byte arrivals becomes one of these. If real
    /// batches cluster at or near 512 bytes, the URL-loading-system-buffering
    /// hypothesis is confirmed; if they do not, it is not.
    func batchArrived(_ batch: ChannelTraceBatch)

    /// The stream ended - cleanly, or with a reason safe to print (never a
    /// raw error's own description, which can carry the request's URL - see
    /// `URLSessionTransport.classify(_:)`). `totalBytes` is every byte the
    /// stream delivered, batched or not, so a sink can sanity-check its own
    /// batch counts against it.
    func streamEnded(outcome: ChannelTraceOutcome, totalBytes: Int, at instant: ContinuousClock.Instant)
}

/// One run of bytes with near-zero gaps between them - `ChannelTraceBatcher`'s
/// unit of output, and `ChannelTraceSink.batchArrived(_:)`'s payload.
public struct ChannelTraceBatch: Sendable, Equatable {
    /// How many bytes arrived in this batch.
    public let byteCount: Int
    /// The time between the previous batch's last byte and this batch's
    /// first - `.zero` for the very first batch of a stream, since there is
    /// no previous batch to measure from.
    public let gapSincePrevious: Duration
    /// When this batch's first byte arrived.
    public let start: ContinuousClock.Instant

    public init(byteCount: Int, gapSincePrevious: Duration, start: ContinuousClock.Instant) {
        self.byteCount = byteCount
        self.gapSincePrevious = gapSincePrevious
        self.start = start
    }
}

/// Why a traced stream's body stopped.
public enum ChannelTraceOutcome: Sendable, Equatable {
    /// The body finished on its own - the ordinary case (`findings.md` §3.5).
    case eof
    /// The body threw. `reason` is a phrase safe to print anywhere - see
    /// `TransportFailureReason.safeDescription` and
    /// `URLSessionTransport.classify(_:)`, which is the only place this
    /// protocol's Darwin-side caller may read a real error's own description,
    /// and it never does.
    case error(String)
}
