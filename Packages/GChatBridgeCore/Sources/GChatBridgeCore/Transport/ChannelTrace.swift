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

    /// One unary or fire-and-forget call completed - `register`, the
    /// acknowledge, the initial ping, or any `/api/` call
    /// `ProtoAPIClient.callRaw` makes. This is what tells the difference
    /// between a message reaching Google and Google dispatching it onward:
    /// the send handler discards `create_message`'s response outright, so
    /// this is the first data this project has ever recorded about what
    /// Google actually says back.
    ///
    /// Takes one `UnaryCallRecord` rather than its fields spelled out -
    /// swiftlint's `function_parameter_count` caps a function at five, and
    /// this call genuinely has more than five independent facts to report.
    func unaryCallCompleted(_ record: UnaryCallRecord)
}

/// `ChannelTraceSink.unaryCallCompleted(_:)`'s payload - see that method's
/// own doc comment for what each field means and when it is `nil`.
public struct UnaryCallRecord: Sendable {
    /// `HTTPRequest.traceLabel` - widened here from streams-only to every
    /// call this transport makes, so `"register"`/`"acknowledge"`/`"ping"`
    /// and an `/api/` method name such as `"create_message"` are all
    /// identified the same way. `"unlabeled"` when absent.
    public let label: String
    public let method: String
    public let requestByteCount: Int
    /// `nil` exactly when the response body was never read -
    /// `HTTPTransport.fireAndForget(_:)`'s own contract, which is the
    /// acknowledge and the ping.
    public let responseByteCount: Int?
    /// `ProtoFieldScan.fields(in:)` run against the raw response bytes,
    /// whatever they turn out to be - `nil` under the same condition as
    /// `responseByteCount`. A channel body is pblite/JSON rather than binary
    /// protobuf, and this reports that unstructured shape rather than
    /// special-casing which calls to scan; it is still only field numbers
    /// and wire types, never a value.
    public let responseBodyShape: ProtoShape?
    public let outcome: UnaryTraceOutcome
    public let duration: Duration
    /// When the request was handed to the transport - **not** when it
    /// completed. `ChannelTraceFileSink` derives the completion instant as
    /// `startedAt + duration` rather than taking it as a second parameter
    /// here, which is what keeps this initialiser at eight parameters rather
    /// than nine against swiftlint's `function_parameter_count` ceiling.
    ///
    /// Recording the start rather than the completion is deliberate: a
    /// caller that only sees the timestamp `unaryCallCompleted(_:)` is named
    /// for would still know exactly when the call was made, because
    /// `duration` is right there next to it. See `findings.md` §26.2 and this
    /// call's own site in `URLSessionTransport.traceUnaryCall(...)`, which
    /// captures this **before** issuing the request and calls this
    /// initialiser only after the response (or failure) is in hand - so a
    /// row's `startedAt` and the moment it is actually appended to the file
    /// are two different instants whenever another row's write races it in
    /// between, which is why the sink writes both a start and an end column
    /// rather than one.
    public let startedAt: ContinuousClock.Instant

    public init(
        label: String,
        method: String,
        requestByteCount: Int,
        responseByteCount: Int?,
        responseBodyShape: ProtoShape?,
        outcome: UnaryTraceOutcome,
        duration: Duration,
        startedAt: ContinuousClock.Instant
    ) {
        self.label = label
        self.method = method
        self.requestByteCount = requestByteCount
        self.responseByteCount = responseByteCount
        self.responseBodyShape = responseBodyShape
        self.outcome = outcome
        self.duration = duration
        self.startedAt = startedAt
    }
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
    /// When this batch's last byte arrived - the same arrival that, once the
    /// *next* byte's gap exceeded `ChannelTraceBatcher.gapThreshold`, is what
    /// closed this batch. Equal to `start` for a single-byte batch.
    ///
    /// This is reported later than it happened by construction: a batch's
    /// `end` cannot be known until either the next batch's first byte proves
    /// no more bytes are coming for this one, or the stream itself ends -
    /// see `ChannelTraceBatcher.arrived(at:byteCount:)`/`flush()`. That gap
    /// between "this instant occurred" and "this row got written" is exactly
    /// what a caller sorting the file by `end` rather than trusting row order
    /// corrects for.
    public let end: ContinuousClock.Instant

    public init(
        byteCount: Int,
        gapSincePrevious: Duration,
        start: ContinuousClock.Instant,
        end: ContinuousClock.Instant
    ) {
        self.byteCount = byteCount
        self.gapSincePrevious = gapSincePrevious
        self.start = start
        self.end = end
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

/// A response body's top-level field-number shape - `ProtoFieldScan.fields(in:)`
/// run against raw bytes, carried alongside whether the walk read the whole
/// body or stopped early. Never a value, never a byte of content.
public struct ProtoShape: Sendable, Equatable {
    public let fields: [ProtoField]
    /// Whether `ProtoFieldScan` stopped before the end of the body - a fact
    /// about the read, not necessarily about the data; see its own doc
    /// comment.
    public let truncated: Bool

    public init(fields: [ProtoField], truncated: Bool) {
        self.fields = fields
        self.truncated = truncated
    }
}

/// Why a unary or fire-and-forget call ended, for
/// `ChannelTraceSink.unaryCallCompleted(...)`.
public enum UnaryTraceOutcome: Sendable, Equatable {
    /// The transport returned - a status the caller may still treat as a
    /// failure (a non-200, or the sign-in shell CLAUDE.md records `/api/`
    /// answering with on this protocol) is still `.completed`; this only
    /// says a response came back at all.
    case completed(status: Int)
    /// The transport itself threw. `reason` is a phrase safe to print
    /// anywhere - the same rule `ChannelTraceOutcome.error(_:)` keeps.
    case error(String)
}
