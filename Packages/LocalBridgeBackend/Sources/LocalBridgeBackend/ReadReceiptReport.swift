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
///
/// A live run reported `receipt self: -0.000s` and `receipt other: +0.000s`
/// against a three-decimal seconds line - a scale that cannot distinguish
/// one microsecond short (uncovered, under an exclusive comparison) from
/// four hundred (also uncovered, but a different bug). Every delta below is
/// therefore a signed microsecond integer, never a rounded second, and every
/// one is stated against one explicit reference so a zero is never
/// ambiguous about what it is zero *of*.
public enum ReadReceiptReport {
    private static let microsecondsPerSecond: Double = 1_000_000

    /// The newest topic's own timing fields, pulled out of the generated
    /// `Topic` at the call site so this file - and its tests - never need to
    /// construct one. `Topic` (proto line 1115) carries two of its own
    /// timestamps (`sort_time`, field 2; `create_time_usec`, field 15), and
    /// its `replies` (field 7) each carry a `create_time` - the live
    /// hypothesis this type exists to let the probe measure is that the
    /// server stamps the topic marginally later than the message inside it,
    /// which would make every `+1µs` mark-as-read land short by a fixed
    /// sub-millisecond amount regardless of message age.
    public struct NewestTopicReference: Sendable {
        /// The stated reference every delta in this report is measured
        /// against - the newest topic's `create_time_usec`.
        public let createTimeUsec: Int64
        /// The same topic's `sort_time` (field 2), or `nil` when the wire
        /// left it unset (`Topic.hasSortTime == false`) - reported as
        /// "not set" rather than a bogus delta against the proto's `0`
        /// default, which would otherwise print as a huge negative number
        /// that is, in effect, the reference's own absolute epoch value
        /// negated.
        public let sortTime: Int64?
        /// The greatest `create_time` among that topic's `replies` (field 7),
        /// or `nil` when the newest topic carried no replies at all.
        public let newestReplyCreateTime: Int64?

        public init(createTimeUsec: Int64, sortTime: Int64?, newestReplyCreateTime: Int64?) {
            self.createTimeUsec = createTimeUsec
            self.sortTime = sortTime
            self.newestReplyCreateTime = newestReplyCreateTime
        }
    }

    /// - Parameters:
    ///   - receiptSet: the rung 4 response's `read_receipt_set` (field 6),
    ///     decoded as-is - nothing here reaches for raw bytes, because the
    ///     vendored proto already names both fields this needs
    ///     (`read_time_micros`, `user`).
    ///   - topicCount: `response.topics.count`, reported so the reader can
    ///     confirm which conversation's response this is.
    ///   - newestTopicReference: the timing fields of the greatest
    ///     `Topic.createTimeUsec` in that same response - the reference
    ///     point every delta and the age line are measured against. `nil`
    ///     when the response carried no topics at all, in which case none of
    ///     them can be computed.
    ///   - selfUserID: this account's own id, from `get_self_user_status`,
    ///     compared against each receipt's `user.userID.id` to label it
    ///     `self`/`other`. `nil` when the probe could not identify itself -
    ///     reported explicitly rather than guessed.
    ///   - now: injectable so the age line is testable without reading the
    ///     clock; defaults to the real time for the live probe.
    public static func lines(
        receiptSet: ReadReceiptSet,
        topicCount: Int,
        newestTopicReference: NewestTopicReference?,
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
        guard let newestTopicReference else {
            lines.append("  no topics in this response - cannot compute an age or a delta")
            return lines
        }
        lines.append(
            "  newest topic age: \(formatted(age(newestTopicReference.createTimeUsec, now: now)))s"
        )
        lines.append(
            "  precision (microseconds, signed, vs newest topic's create_time_usec "
                + "as the stated reference - zero means exactly at it):"
        )
        appendReceiptLines(
            receiptSet.readReceipts,
            referenceUsec: newestTopicReference.createTimeUsec,
            selfUserID: selfUserID,
            into: &lines
        )
        appendTopicTimingLines(newestTopicReference, into: &lines)
        return lines
    }

    private static func appendReceiptLines(
        _ receipts: [ReadReceipt],
        referenceUsec: Int64,
        selfUserID: String?,
        into lines: inout [String]
    ) {
        guard !receipts.isEmpty else { return }
        if selfUserID == nil {
            lines.append("    self could not be identified - receipts reported by index only")
        }
        for (index, receipt) in receipts.enumerated() {
            let who = whoLabel(receipt: receipt, selfUserID: selfUserID, index: index)
            let delta = deltaMicros(readTimeMicros: receipt.readTimeMicros, referenceUsec: referenceUsec)
            lines.append("    receipt \(who): \(formattedMicros(delta)) vs reference")
        }
    }

    /// The newest topic's own three timestamps against its own
    /// `create_time_usec` as reference - printed whenever a newest topic
    /// exists, independent of whether any receipt does, because these three
    /// numbers are what distinguishes "our mark falls short of the message"
    /// from "our mark falls short of the topic", the two competing
    /// explanations this probe exists to tell apart.
    private static func appendTopicTimingLines(
        _ reference: NewestTopicReference,
        into lines: inout [String]
    ) {
        if let sortTime = reference.sortTime {
            let delta = sortTime - reference.createTimeUsec
            lines.append("    newest topic sort_time: \(formattedMicros(delta)) vs reference")
        } else {
            lines.append("    newest topic sort_time: not set on this topic")
        }
        lines.append(
            "    newest topic create_time_usec: "
                + "\(formattedMicros(0)) vs reference (this field is the reference itself)"
        )
        if let newestReplyCreateTime = reference.newestReplyCreateTime {
            let delta = newestReplyCreateTime - reference.createTimeUsec
            lines.append("    newest reply create_time: \(formattedMicros(delta)) vs reference")
        } else {
            lines.append("    newest reply create_time: no replies in newest topic")
        }
    }

    private static func whoLabel(receipt: ReadReceipt, selfUserID: String?, index: Int) -> String {
        guard let selfUserID else { return "index \(index)" }
        return receipt.user.userID.id == selfUserID ? "self" : "other"
    }

    /// Seconds between `newestCreateTimeUsec` and `now` - always positive for
    /// a real message, reported so the reader can confirm the probe hit the
    /// conversation the repro actually happened in. Orientation only, which
    /// is why this stays in seconds while every delta below it is
    /// microseconds - nobody needs microsecond precision to confirm "yes,
    /// that is the conversation from a few minutes ago".
    static func age(_ newestCreateTimeUsec: Int64, now: Date) -> Double {
        (now.timeIntervalSince1970 * microsecondsPerSecond - Double(newestCreateTimeUsec))
            / microsecondsPerSecond
    }

    /// Signed microseconds: `readTimeMicros` minus `referenceUsec`. Zero or
    /// positive means the receipt covers the reference; negative means it is
    /// short by that many microseconds - exact, because Google's read
    /// comparison is exclusive (`findings.md` §36) and a receipt even one
    /// microsecond short does not cover the message it names. `Int64`
    /// subtraction, so no rounding is possible in either direction.
    static func deltaMicros(readTimeMicros: Int64, referenceUsec: Int64) -> Int64 {
        readTimeMicros - referenceUsec
    }

    private static func formatted(_ seconds: Double) -> String {
        String(format: "%.3f", seconds)
    }

    private static func formattedMicros(_ delta: Int64) -> String {
        delta >= 0 ? "+\(delta)µs" : "\(delta)µs"
    }
}
