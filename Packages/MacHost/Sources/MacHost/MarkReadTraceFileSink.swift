import Foundation
import SyncEngine

/// Writes the automatic mark-read trigger's evidence to a CSV file, as it
/// happens - `--probe=markread`'s own instrument, mirroring
/// `ChannelTraceFileSink` in `URLSessionTransport` almost line for line.
///
/// **Lives here, not in `SyncEngine` next to `MarkReadTraceSink`.**
/// `MarkReadTraceSink` is Foundation-only so `SyncEngine`'s reducer stays free
/// of file I/O the same way `GChatBridgeCore`'s core stays free of `Network`;
/// a concrete file-writing conformance belongs beside `AppNapProbe` and the
/// other probes, which is what `MacHost` already holds. Unlike
/// `ChannelTraceFileSink`, this can live in `MacHost` outright rather than
/// needing a `GChatBridgeCore`-only home: `MarkReadTraceSink` is declared in
/// `SyncEngine`, which `MacHost` already depends on and may import freely -
/// there is no core-containment rule blocking it the way there is for
/// `GChatBridgeCore`.
///
/// **Cost and write-through discipline are identical to `ChannelTraceFileSink`:**
/// a `FileHandle` open, seek-to-end, write and close per event, guarded by
/// `lock` so concurrent writers can never race that sequence
/// (`findings.md` §26.1), and no buffering - the owner routinely kills the app
/// mid-run, so anything buffered is lost (§26.2). `nil` on every ordinary
/// launch, so this file is never touched unless `--probe=markread` was asked
/// for.
public final class MarkReadTraceFileSink: MarkReadTraceSink {
    private static let header = [
        "elapsedSeconds", "row", "conversation", "outcome", "loadedMessageCount",
        "filteredMessageCount", "newestAgeSeconds", "unreadCount", "accepted", "durationMillis"
    ].joined(separator: ",")

    private let url: URL
    /// Every row's elapsed time is reported relative to this - a
    /// `ContinuousClock` reading taken once, at construction - never a wall
    /// clock, for the same reason `ChannelTraceFileSink.origin` gives.
    private let origin = ContinuousClock.now
    /// Guards the open-seek-write sequence in `appendRow` - see this type's
    /// own doc comment, and `ChannelTraceFileSink`'s, for the corruption that
    /// ran without one.
    private let lock = NSLock()

    public init(writingTo url: URL) {
        self.url = url
        try? (Self.header + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    public func triggerEvaluated(_ record: MarkReadTriggerRecord) {
        appendRow(
            at: record.at,
            row: "trigger",
            conversation: record.conversation.map(String.init) ?? "",
            outcome: record.outcome.rawValue,
            loadedMessageCount: String(record.loadedMessageCount),
            filteredMessageCount: String(record.filteredMessageCount),
            newestAgeSeconds: record.newestAgeSeconds.map(Self.formatted) ?? "",
            unreadCount: record.unreadCount.map(String.init) ?? ""
        )
    }

    public func markOutcome(_ record: MarkReadOutcomeRecord) {
        appendRow(
            at: record.at,
            row: "outcome",
            conversation: String(record.conversation),
            accepted: record.accepted ? "true" : "false",
            durationMillis: Self.milliseconds(record.duration)
        )
    }

    public func readStateChanged(_ record: MarkReadStateRecord) {
        appendRow(
            at: record.at,
            row: "readState",
            conversation: String(record.conversation),
            unreadCount: String(record.unreadCount)
        )
    }

    // MARK: - Writing

    private func appendRow(
        at instant: ContinuousClock.Instant,
        row: String,
        conversation: String = "",
        outcome: String = "",
        loadedMessageCount: String = "",
        filteredMessageCount: String = "",
        newestAgeSeconds: String = "",
        unreadCount: String = "",
        accepted: String = "",
        durationMillis: String = ""
    ) {
        let fields = [
            Self.seconds(instant - origin), row, conversation, outcome,
            loadedMessageCount, filteredMessageCount, newestAgeSeconds, unreadCount, accepted, durationMillis
        ].map(Self.sanitized)
        let line = fields.joined(separator: ",") + "\n"
        // The whole open-seek-write sequence is the critical section, same as
        // `ChannelTraceFileSink.appendRow` - splitting the lock any finer
        // would still let two handles race their own `seekToEnd()` calls.
        lock.withLock {
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }

    /// Fixed-point formatting, pinned to a POSIX locale so a decimal comma (as
    /// `%f` would print under several real locales) can never land inside a
    /// comma-separated column - same as `ChannelTraceFileSink.seconds(_:)`.
    private static func seconds(_ duration: Duration) -> String {
        let value = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return formatted(value)
    }

    private static func formatted(_ value: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func milliseconds(_ duration: Duration) -> String {
        let value = Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1e15
        return String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    /// Strips anything that would break a CSV column - a comma or a
    /// newline - rather than escaping it. Every value passed here is a count,
    /// a duration, an age or a guard token (never message content, a
    /// conversation title, a cookie or a token), so none of them need to
    /// survive byte-for-byte to remain useful for what this instrument
    /// answers.
    private static func sanitized(_ field: String) -> String {
        field
            .replacingOccurrences(of: ",", with: ";")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}
