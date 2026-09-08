import Foundation

/// Microseconds since the epoch, which is the unit this protocol uses for
/// every timestamp (`findings.md` §2.3).
///
/// Extracted because the conversion was written inline twice in
/// `ChannelEventMapping` and this slice adds two more sites - a `Date` going
/// out on `mark_group_readstate`, and a `view_time` coming back on
/// `GROUP_VIEWED`. Four copies of the same division is how the channel and
/// the history call drift apart on the one detail neither can afford to get
/// wrong.
enum Microseconds {
    /// Clamped rather than trapping. `Int64(_:)` on a `Double` outside
    /// `Int64`'s range is a runtime crash, and the only way to reach that here
    /// is a `Date` no message could carry - so the honest failure is a
    /// saturated timestamp, not a dead process.
    static func from(_ date: Date) -> Int64 {
        let micros = (date.timeIntervalSince1970 * 1_000_000).rounded()
        guard micros.isFinite else { return 0 }
        if micros >= Double(Int64.max) {
            return .max
        }
        if micros <= Double(Int64.min) {
            return .min
        }
        return Int64(micros)
    }

    static func date(_ value: Int64) -> Date {
        Date(timeIntervalSince1970: Double(value) / 1_000_000)
    }

    /// Adds `offset` to `value`, clamped to `Int64`'s range rather than
    /// trapping. `Microseconds.from(_:)` already saturates at `Int64.max`
    /// for a `Date` outside its range, and `Int64.max + 1` is a runtime
    /// crash in Swift's ordinary `+` - so a caller adding a fixed offset
    /// to an already-saturated value (`LocalBridgeBackend
    /// .readPositionOffsetMicroseconds`, session 21's mark-read boundary
    /// experiment) must go through this rather than `+`, the same "clamped,
    /// not trapping" reasoning `from(_:)`'s own doc comment gives.
    static func adding(_ offset: Int64, to value: Int64) -> Int64 {
        let (sum, overflowed) = value.addingReportingOverflow(offset)
        guard overflowed else { return sum }
        return offset > 0 ? .max : .min
    }
}
