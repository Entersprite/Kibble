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
/// **Cost**: a `FileHandle` open, seek-to-end, write and close per event.
/// Real, but paid only on the one `URLSessionTransport` instance
/// `--probe=channeltrace` asks for - `channelTrace` is `nil` on every other
/// construction site, and `URLSessionTransport.stream()` never allocates one
/// of these itself, so a normal launch never touches this file at all.
public final class ChannelTraceFileSink: ChannelTraceSink {
    private static let header = [
        "elapsedSeconds", "event", "kind", "status", "contentType", "contentEncoding",
        "transferEncoding", "gapMillis", "byteCount", "totalBytes", "outcome", "httpMethod",
        "requestByteCount", "responseByteCount", "durationMillis", "protoFields", "truncated"
    ].joined(separator: ",")

    private let url: URL
    /// Every row's timestamp is reported relative to this - a
    /// `ContinuousClock` reading taken once, at construction - never a wall
    /// clock. `ChannelTraceSink`'s own header explains why: a Mac that sleeps
    /// mid-run must not turn a real gap into a fabricated one, or vice versa.
    private let start = ContinuousClock.now

    public init(writingTo url: URL) {
        self.url = url
        try? (Self.header + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    public func streamOpened(kind: String, at instant: ContinuousClock.Instant) {
        appendRow(at: instant, event: "open", kind: kind)
    }

    public func responseHeadReceived(
        status: Int,
        contentType: String?,
        contentEncoding: String?,
        transferEncoding: String?,
        at instant: ContinuousClock.Instant
    ) {
        appendRow(
            at: instant,
            event: "head",
            status: String(status),
            contentType: contentType ?? "",
            contentEncoding: contentEncoding ?? "",
            transferEncoding: transferEncoding ?? ""
        )
    }

    public func batchArrived(_ batch: ChannelTraceBatch) {
        appendRow(
            at: batch.start,
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
        appendRow(at: instant, event: "end", totalBytes: String(totalBytes), outcome: outcomeText)
    }

    /// `responseByteCount`/`responseBodyShape` being `nil` (a fire-and-forget
    /// call - the acknowledge or the ping) is what tells `event` apart from a
    /// call whose body was read (`register`, or an `/api/` call) - see
    /// `ChannelTraceSink.unaryCallCompleted(...)`'s own doc comment.
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
            at: record.instant,
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
        at instant: ContinuousClock.Instant,
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
            Self.seconds(instant - start), event, kind, status, contentType, contentEncoding,
            transferEncoding, gapMillis, byteCount, totalBytes, outcome, httpMethod, requestByteCount,
            responseByteCount, durationMillis, protoFields, truncated
        ].map(Self.sanitized)
        let line = fields.joined(separator: ",") + "\n"
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
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
