import Foundation
import GChatBridgeCore

/// Formats `ListTopicsResponse.readReceiptSet` (field 6) into the report
/// `APIProbeReport+History.swift` appends - the decisive evidence session
/// 21's remaining repro needs: what does Google itself think our read
/// position is, once we have provably published the newest message's
/// timestamp + 1 microsecond (`findings.md` §36).
///
/// Kept pure and separate from the `/api/` call itself so the decoding and
/// delta arithmetic can be tested against an invented `ReadReceiptSet` with
/// no network and no account - the same posture `TopicsRequestLadder.report`
/// already takes for its own rungs.
///
/// **Booleans, counts, self/other and durations only - never a raw user id,
/// a display name or an absolute timestamp.** The rule this probe has
/// followed since §21.4's "by index, never by id or name", extended here to
/// receipts.
public enum ReadReceiptReport {
    /// `read_time_micros` and `create_time_usec` are both microseconds since
    /// the Unix epoch - the same convention `WorldMapping.swift:78` already
    /// relies on for `sort_timestamp`.
    private static let microsecondsPerSecond: Double = 1_000_000

    /// - Parameters:
    ///   - receiptSet: the rung 4 response's `read_receipt_set` (field 6),
    ///     decoded as-is - nothing here reaches for raw bytes, because the
    ///     vendored proto already names both fields this needs
    ///     (`read_time_micros`, `user`).
    ///   - topicCount: `response.topics.count`, reported so the reader can
    ///     confirm which conversation's response this is.
    ///   - newestCreateTimeUsec: the greatest `Topic.createTimeUsec` in that
    ///     same response - the reference point every delta and the age line
    ///     are measured against. `nil` when the response carried no topics at
    ///     all, in which case neither can be computed.
    ///   - selfUserID: this account's own id, from `get_self_user_status`,
    ///     compared against each receipt's `user.userID.id` to label it
    ///     `self`/`other`. `nil` when the probe could not identify itself -
    ///     reported explicitly rather than guessed.
    ///   - now: injectable so the age line is testable without reading the
    ///     clock; defaults to the real time for the live probe.
    public static func lines(
        receiptSet: ReadReceiptSet,
        topicCount: Int,
        newestCreateTimeUsec: Int64?,
        selfUserID: String?,
        now: Date = Date()
    ) -> [String] {
        var lines = ["read receipts (list_topics rung 4, fetch_options incl. READ_RECEIPTS):"]
        lines.append("  topics returned: \(topicCount)")
        lines.append("  read receipts enabled: \(receiptSet.enabled)")
        guard receiptSet.enabled else {
            lines.append(
                "  DISABLED for this account - nothing this client does could ever "
                    + "produce a receipt here; this line ends the investigation."
            )
            return lines
        }
        lines.append("  receipts: \(receiptSet.readReceipts.count)")
        guard let newestCreateTimeUsec else {
            lines.append("  no topics in this response - cannot compute an age or a delta")
            return lines
        }
        lines.append("  newest topic age: \(formatted(age(newestCreateTimeUsec, now: now)))s")
        appendReceiptLines(
            receiptSet.readReceipts,
            newestCreateTimeUsec: newestCreateTimeUsec,
            selfUserID: selfUserID,
            into: &lines
        )
        return lines
    }

    private static func appendReceiptLines(
        _ receipts: [ReadReceipt],
        newestCreateTimeUsec: Int64,
        selfUserID: String?,
        into lines: inout [String]
    ) {
        guard !receipts.isEmpty else { return }
        if selfUserID == nil {
            lines.append("  self could not be identified - receipts reported by index only")
        }
        for (index, receipt) in receipts.enumerated() {
            let who = whoLabel(receipt: receipt, selfUserID: selfUserID, index: index)
            let delta = delta(
                readTimeMicros: receipt.readTimeMicros,
                newestCreateTimeUsec: newestCreateTimeUsec
            )
            lines.append("    receipt \(who): \(formatted(delta, signed: true))s vs newest topic")
        }
    }

    private static func whoLabel(receipt: ReadReceipt, selfUserID: String?, index: Int) -> String {
        guard let selfUserID else { return "index \(index)" }
        return receipt.user.userID.id == selfUserID ? "self" : "other"
    }

    /// Seconds between `newestCreateTimeUsec` and `now` - always positive for
    /// a real message, reported so the reader can confirm the probe hit the
    /// conversation the repro actually happened in.
    static func age(_ newestCreateTimeUsec: Int64, now: Date) -> Double {
        (now.timeIntervalSince1970 * microsecondsPerSecond - Double(newestCreateTimeUsec))
            / microsecondsPerSecond
    }

    /// Signed seconds: `read_time_micros` minus the newest topic's
    /// `create_time_usec`. Zero or positive means the receipt covers the
    /// newest message; negative means it is behind by that much - the exact
    /// number this investigation exists to produce.
    static func delta(readTimeMicros: Int64, newestCreateTimeUsec: Int64) -> Double {
        Double(readTimeMicros - newestCreateTimeUsec) / microsecondsPerSecond
    }

    private static func formatted(_ seconds: Double, signed: Bool = false) -> String {
        signed ? String(format: "%+.3f", seconds) : String(format: "%.3f", seconds)
    }
}
