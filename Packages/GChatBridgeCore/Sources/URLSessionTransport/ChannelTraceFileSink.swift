import Foundation
import GChatBridgeCore

/// Writes one long-poll stream's transport-level behaviour to a CSV file, as
/// it happens.
///
/// **Lives here, in the `URLSessionTransport` target, rather than in
/// `MacHost` alongside `AppNapProbe`/`LoginTrace`.** `ChannelTraceSink` is
/// declared in `GChatBridgeCore`, and CLAUDE.md's containment rule -
/// "`LocalBridgeBackend` is the only package that may import
/// `GChatBridgeCore`", enforced by `scripts/test.sh`'s core-containment scan -
/// means a conformance to it cannot live in `MacHost` at all: writing `final
/// class Foo: ChannelTraceSink` requires spelling that protocol's name, which
/// requires importing the module that declares it, which `MacHost` may not.
/// `NWPathReachabilityMonitor` next to this file settles the identical
/// tension the identical way: a concrete conformance to a core-declared
/// protocol that needs something the core itself must not have - there,
/// `Network`; here, nothing more exotic than ordinary file I/O, which the
/// core *could* technically compile but is kept out of on purpose to stay a
/// pure, no-side-effects seam reusable by a future bridge server.
/// `SessionHandoff.swift`, inside `LocalBridgeBackend` - the one package
/// allowed to know both this type and `GChatBridgeCore`'s `ChannelTraceSink` -
/// is what actually constructs one of these; `MacHost` only ever hands it a
/// destination `URL`, exactly as it hands `AppNapProbe`
/// `SystemLaunchServices.supportDirectory()`.
///
/// **Cost**: a `FileHandle` open, seek-to-end, write and close per event,
/// serialised behind `lock` so two concurrent events can never race that
/// sequence. Real, but paid only on the one `URLSessionTransport` instance
/// `--probe=channeltrace` asks for - `channelTrace` is `nil` on every other
/// construction site, and `URLSessionTransport.stream()` never allocates one
/// of these itself, so a normal launch never touches this file at all.
///
/// **Why `lock` exists.** A live capture once showed a row with its leading
/// fields blank and every later column shifted - no timestamp, no event
/// name, `completed`/`GET`/a real duration landing under the wrong headers.
/// No branch in this file or in `URLSessionTransport.traceUnaryCall(...)`
/// ever builds a row with fewer than the full field list - `appendRow`'s own
/// `fields` array below is unconditional - so no single call here can have
/// produced it. What can, and does: this transport genuinely issues calls
/// concurrently (the register and the bootstrap's own API calls overlap on
/// startup), and every call site reached `FileHandle(forWritingTo:)`,
/// `seekToEnd()` and `write(contentsOf:)` as three separate, unsynchronised
/// steps. Two `appendRow` calls racing that sequence can both `seekToEnd()`
/// to the same offset before either has written, and whichever writes
/// *second* overwrites the head of whichever wrote *first* - without
/// truncating it, so the first row's own untouched tail survives as a
/// following line missing exactly the bytes the second row's own length
/// consumed. That is this bug (`findings.md` §26.1), reproduced under real
/// concurrency by `ChannelTraceFileSinkConcurrencyTests`. `lock` makes the open-seek-write
/// sequence one critical section, which is sufficient: every writer still
/// goes through this same sink instance, there is exactly one file, and nothing
/// here needs to coordinate with a second process.
public final class ChannelTraceFileSink: ChannelTraceSink {
    private static let header = [
        "startSeconds", "endSeconds", "event", "kind", "status", "contentType", "contentEncoding",
        "transferEncoding", "gapMillis", "byteCount", "totalBytes", "outcome", "httpMethod",
        "requestByteCount", "responseByteCount", "durationMillis", "protoFields", "truncated"
    ].joined(separator: ",")

    private let url: URL
    /// Every row's two timestamps are reported relative to this - a
    /// `ContinuousClock` reading taken once, at construction - never a wall
    /// clock. `ChannelTraceSink`'s own header explains why: a Mac that sleeps
    /// mid-run must not turn a real gap into a fabricated one, or vice versa.
    private let origin = ContinuousClock.now
    /// Guards the open-seek-write sequence in `appendRow` - see this type's
    /// own doc comment for the corruption that ran without it. This repo's
    /// existing idiom for exactly this job; `NWPathReachabilityMonitor.swift`,
    /// right next to this file, guards its own state the same way.
    private let lock = NSLock()

    public init(writingTo url: URL) {
        self.url = url
        try? (Self.header + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    public func streamOpened(kind: String, at instant: ContinuousClock.Instant) {
        appendRow(start: instant, end: instant, event: "open", kind: kind)
    }

    public func responseHeadReceived(
        status: Int,
        contentType: String?,
        contentEncoding: String?,
        transferEncoding: String?,
        at instant: ContinuousClock.Instant
    ) {
        appendRow(
            start: instant,
            end: instant,
            event: "head",
            status: String(status),
            contentType: contentType ?? "",
            contentEncoding: contentEncoding ?? "",
            transferEncoding: transferEncoding ?? ""
        )
    }

    public func batchArrived(_ batch: ChannelTraceBatch) {
        appendRow(
            start: batch.start,
            end: batch.end,
            event: "batch",
            gapMillis: Self.milliseconds(batch.gapSincePrevious),
            byteCount: String(batch.byteCount)
        )
    }

    public func streamEnded(
        outcome: ChannelTraceOutcome,
        totalBytes: Int,
        at instant: ContinuousClock.Instant
    ) {
        let outcomeText = switch outcome {
        case .eof: "eof"
        case let .error(reason): "error:\(reason)"
        }
        appendRow(
            start: instant, end: instant, event: "end", totalBytes: String(totalBytes), outcome: outcomeText
        )
    }

    /// `responseByteCount`/`responseBodyShape` being `nil` (a fire-and-forget
    /// call - the acknowledge or the ping) is what tells `event` apart from a
    /// call whose body was read (`register`, or an `/api/` call) - see
    /// `ChannelTraceSink.unaryCallCompleted(...)`'s own doc comment.
    ///
    /// The row's `end` is derived as `startedAt + duration` rather than
    /// carried on `UnaryCallRecord` itself - see that type's own doc comment
    /// on `startedAt` for why - and it is that derived value, not
    /// `startedAt`, that a reader sorting the file chronologically should
    /// trust: `startedAt` is stamped before the call was issued, but this row
    /// is not appended until the call has already completed, so a slower
    /// concurrent call started earlier can still be written later.
    public func unaryCallCompleted(_ record: UnaryCallRecord) {
        let statusText: String
        let outcomeText: String
        switch record.outcome {
        case let .completed(status):
            statusText = String(status)
            outcomeText = "completed"
        case let .error(reason):
            statusText = ""
            outcomeText = "error:\(reason)"
        }
        appendRow(
            start: record.startedAt,
            end: record.startedAt + record.duration,
            event: record.responseByteCount == nil ? "fireAndForget" : "call",
            kind: record.label,
            status: statusText,
            outcome: outcomeText,
            httpMethod: record.method,
            requestByteCount: String(record.requestByteCount),
            responseByteCount: record.responseByteCount.map(String.init) ?? "",
            durationMillis: Self.milliseconds(record.duration),
            protoFields: record.responseBodyShape.map(Self.formattedFields) ?? "",
            truncated: record.responseBodyShape.map { $0.truncated ? "true" : "false" } ?? ""
        )
    }

    // MARK: - Writing

    private func appendRow(
        start: ContinuousClock.Instant,
        end: ContinuousClock.Instant,
        event: String,
        kind: String = "",
        status: String = "",
        contentType: String = "",
        contentEncoding: String = "",
        transferEncoding: String = "",
        gapMillis: String = "",
        byteCount: String = "",
        totalBytes: String = "",
        outcome: String = "",
        httpMethod: String = "",
        requestByteCount: String = "",
        responseByteCount: String = "",
        durationMillis: String = "",
        protoFields: String = "",
        truncated: String = ""
    ) {
        let fields = [
            Self.seconds(start - origin), Self.seconds(end - origin), event, kind, status, contentType,
            contentEncoding, transferEncoding, gapMillis, byteCount, totalBytes, outcome, httpMethod,
            requestByteCount, responseByteCount, durationMillis, protoFields, truncated
        ].map(Self.sanitized)
        let line = fields.joined(separator: ",") + "\n"
        // The whole open-seek-write sequence is the critical section - see
        // this type's own doc comment. Splitting the lock any finer (e.g.
        // only around `write`) would still let two handles race their
        // `seekToEnd()` calls against each other.
        lock.withLock {
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }

    /// `number:wireType:byteCount`, `|`-joined - compact, and never a comma,
    /// so `sanitized(_:)` has nothing to rewrite in this column. Field
    /// numbers and wire types only, exactly what `ProtoFieldScan` reports;
    /// never a value.
    ///
    /// Not `private`: `ChannelTraceFileSinkTests` exercises this directly as
    /// the pure part of an otherwise file-writing sink, the same boundary
    /// this type's own doc comment already draws for `SecItem`/`WKWebView`.
    static func formattedFields(_ shape: ProtoShape) -> String {
        shape.fields.map { "\($0.number):\($0.wireType):\($0.byteCount)" }.joined(separator: "|")
    }

    /// Fixed-point formatting, pinned to a POSIX locale so a decimal comma
    /// (as `%f` would print under several real locales) can never land inside
    /// a comma-separated column.
    private static func seconds(_ duration: Duration) -> String {
        let value = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        return String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func milliseconds(_ duration: Duration) -> String {
        let value = Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1e15
        return String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    /// Strips anything that would break a CSV column - a comma or a
    /// newline - rather than escaping it. Every value passed here is a status
    /// number, a count, or a short header value (never a URL, a cookie or
    /// message content - see `ChannelTraceSink`'s own header), so none of them
    /// need to survive byte-for-byte to remain useful for what this
    /// instrument answers.
    private static func sanitized(_ field: String) -> String {
        field
            .replacingOccurrences(of: ",", with: ";")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}
