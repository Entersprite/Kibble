import ChatKit
import Foundation
import GChatBridgeCore

/// How far each conversation's read position falls short of its own head
/// time - the diagnosis session 29 exists for. Three hypotheses are open
/// (`.superpowers/sdd/read-state-diagnosis/brief.md`):
///
/// 1. This client publishes one microsecond past the newest message it has
///    *loaded*, and Google's own field 29 is later than that - the mark
///    never covers the head.
/// 2. Google's own clients store `last_read_time == head` exactly, so the
///    2026-09-23 flip from `>` to `>=` (§37.9) reads every conversation read
///    elsewhere as unread here.
/// 3. The world snapshot lags a just-published mark.
///
/// This file only measures. **Counts, microsecond deltas, ages and kind
/// tokens only - never an id, a name or any text.** The report is pasted
/// into a committed file.
///
/// Split into its own file for the same `file_length` reason
/// `APIProbeReport+WorldFields.swift` and `APIProbeReport+Mentions.swift`
/// already are.
struct ReadPositionDeltaCounts: Equatable {
    var covered = 0
    var equal = 0
    var upToOneMillisecond = 0
    var upToOneSecond = 0
    var upToOneHour = 0
    var older = 0
    var notComparable = 0
}

/// One histogram plus the smallest positive deltas that produced it - pure
/// data, computed by `APIProbeReport.readPositionDeltas(_:)` and rendered by
/// `APIProbeReport.readPositionDeltaLines(_:)`, split apart so both halves
/// are testable with no network.
struct ReadPositionDeltas: Equatable {
    var all = ReadPositionDeltaCounts()

    /// Keyed by `APIProbeReport.kindWireToken(_:)` - only kinds that
    /// actually occur, so an account with no `meetChat` never gets a zeroed
    /// row for it.
    var byKind: [String: ReadPositionDeltaCounts] = [:]

    /// Every positive `d` no greater than one second, in encounter order and
    /// uncapped - `readPositionDeltaLines(_:)` is the only place that sorts
    /// and caps how many print, the same split `MentionShapes.spanDetails`
    /// already takes.
    var smallestPositiveDeltas: [Int64] = []
}

/// The probed conversation's own three figures - pure data, computed by
/// `APIProbeReport.probedConversationFigures(...)` and rendered by
/// `APIProbeReport.probedConversationLine(_:)`.
struct ProbedConversationFigures: Equatable {
    var newestMinusReadPosition: Int64?
    var headMinusNewestMessage: Int64?
    var newestMessageAgeSeconds: Double?
}

extension APIProbeReport {
    private static let oneMillisecond: Int64 = 1000
    private static let oneSecond: Int64 = 1_000_000
    private static let oneHour: Int64 = 3_600_000_000
    private static let maxSmallestPositive = 5

    // MARK: - Change 1: the histogram over every world item

    /// For every item whose `read_state` carries both timestamps (typed
    /// accessors, per §39.1 - never `unknownFields`), `d = head - lastRead`,
    /// bucketed and split by kind. An item missing either field counts as
    /// `notComparable` in both `all` and its own kind's row, never as
    /// `equal` - the same trap the typed-decode rule names for a different
    /// pair of fields.
    static func readPositionDeltas(_ items: [WorldItemLite]) -> ReadPositionDeltas {
        var deltas = ReadPositionDeltas()
        for item in items {
            let token = kindWireToken(WorldMapping.kind(for: item))
            var kindCounts = deltas.byKind[token, default: ReadPositionDeltaCounts()]
            guard let head = headTime(item), let read = lastReadTime(item) else {
                deltas.all.notComparable += 1
                kindCounts.notComparable += 1
                deltas.byKind[token] = kindCounts
                continue
            }
            let deltaValue = delta(minuend: head, subtrahend: read)
            deltas.all[keyPath: bucket(for: deltaValue)] += 1
            kindCounts[keyPath: bucket(for: deltaValue)] += 1
            deltas.byKind[token] = kindCounts
            if deltaValue > 0, deltaValue <= oneSecond {
                deltas.smallestPositiveDeltas.append(deltaValue)
            }
        }
        return deltas
    }

    /// `all`, then one row per kind that occurs in ascending token order,
    /// then the five smallest positive deltas (µs) ascending.
    static func readPositionDeltaLines(_ deltas: ReadPositionDeltas) -> [String] {
        var lines = ["  newest minus read position (µs; covered < 0 = read):"]
        lines.append(readPositionDeltaCountsLine("all", deltas.all))
        for token in deltas.byKind.keys.sorted() {
            lines.append(readPositionDeltaCountsLine(
                token,
                deltas.byKind[token] ?? ReadPositionDeltaCounts()
            ))
        }
        let smallest = deltas.smallestPositiveDeltas.sorted().prefix(maxSmallestPositive)
        lines.append("    smallest positive (≤1s): [\(smallest.map(String.init).joined(separator: ", "))]")
        return lines
    }

    private static func readPositionDeltaCountsLine(
        _ label: String,
        _ counts: ReadPositionDeltaCounts
    ) -> String {
        "    \(label): covered \(counts.covered), equal \(counts.equal), "
            + "≤1ms \(counts.upToOneMillisecond), ≤1s \(counts.upToOneSecond), "
            + "≤1h \(counts.upToOneHour), older \(counts.older), not comparable \(counts.notComparable)"
    }

    /// `..<0`, `0`, `1...1ms`, `(1ms+1)...1s`, `(1s+1)...1h`, else `older` -
    /// one switch, reused for both `all` and a per-kind row so the two can
    /// never disagree about where an edge lands.
    private static func bucket(for delta: Int64) -> WritableKeyPath<ReadPositionDeltaCounts, Int> {
        switch delta {
        case ..<0:
            \.covered
        case 0:
            \.equal
        case 1 ... oneMillisecond:
            \.upToOneMillisecond
        case (oneMillisecond + 1) ... oneSecond:
            \.upToOneSecond
        case (oneSecond + 1) ... oneHour:
            \.upToOneHour
        default:
            \.older
        }
    }

    // MARK: - Change 2: the probed conversation's own figures

    /// `headTime`, `lastReadTime` and `newestMessageCreateTime` are each
    /// independently optional - `n/a` in the rendered line, never a
    /// fabricated zero. `now` is injectable so the age figure is testable
    /// without reading the clock.
    static func probedConversationFigures(
        headTime: Int64?,
        lastReadTime: Int64?,
        newestMessageCreateTime: Int64?,
        now: Date
    ) -> ProbedConversationFigures {
        func pairedDelta(_ minuend: Int64?, _ subtrahend: Int64?) -> Int64? {
            paired(minuend, subtrahend) { delta(minuend: $0, subtrahend: $1) }
        }
        return ProbedConversationFigures(
            newestMinusReadPosition: pairedDelta(headTime, lastReadTime),
            headMinusNewestMessage: pairedDelta(headTime, newestMessageCreateTime),
            newestMessageAgeSeconds: newestMessageCreateTime.map { ReadReceiptReport.age($0, now: now) }
        )
    }

    static func probedConversationLine(_ figures: ProbedConversationFigures) -> String {
        "  probed conversation: newest minus read position "
            + "\(formattedMicroseconds(figures.newestMinusReadPosition)); "
            + "field 29 minus newest list_topics message create_time "
            + "\(formattedMicroseconds(figures.headMinusNewestMessage)); "
            + "newest list_topics message age \(formattedAge(figures.newestMessageAgeSeconds))"
    }

    /// The probed conversation's own network call - a fifth `list_topics`
    /// call on the minimum-viable rung, `appendMentionShapesSection`'s own
    /// pattern: `TopicsRungResult` keeps no typed message around, so
    /// re-fetching is how this probe gets one. Matches the world item by
    /// re-deriving its `Conversation.ID` through `ChannelEventMapping`,
    /// never by comparing a raw `GroupId` - `WorldMapping.conversation(from:)`
    /// builds `conversation.id` the same way, so this is guaranteed to agree
    /// with it regardless of anything else a `GroupId` might carry.
    static func appendProbedReadPositionLine(
        client: ProtoAPIClient,
        rung: TopicsRequestLadder.Rung,
        conversationID: Conversation.ID,
        worldItems: [WorldItemLite],
        lines: inout [String]
    ) async {
        let response: ListTopicsResponse
        do {
            response = try await client.call(.listTopics, rung.request)
        } catch {
            lines.append("  probed conversation: FAILED: \(safeDescription(of: error))")
            return
        }
        let newestMessageCreateTime = response.topics.flatMap(\.replies).map(\.createTime).max()
        let item = worldItems.first { ChannelEventMapping.conversationID($0.groupID) == conversationID }
        let figures = probedConversationFigures(
            headTime: item.flatMap(headTime),
            lastReadTime: item.flatMap(lastReadTime),
            newestMessageCreateTime: newestMessageCreateTime,
            now: Date()
        )
        lines.append(probedConversationLine(figures))
    }

    // MARK: - Shared arithmetic and typed-accessor reads

    /// `GroupReadState.last_head_message_create_time_usec`, read through the
    /// typed accessor only - never `unknownFields` (§39.1's reverse trap).
    private static func headTime(_ item: WorldItemLite) -> Int64? {
        item.readState.hasLastHeadMessageCreateTimeUsec ? item.readState.lastHeadMessageCreateTimeUsec : nil
    }

    /// `GroupReadState.last_read_time`, likewise.
    private static func lastReadTime(_ item: WorldItemLite) -> Int64? {
        item.readState.hasLastReadTime ? item.readState.lastReadTime : nil
    }

    /// `minuend - subtrahend`, never trapping. No real microsecond timestamp
    /// pair can overflow an `Int64` difference, but `subtractingReportingOverflow`
    /// costs nothing and settles the brief's own requirement: an overflow is
    /// resolved by comparing the two operands directly - never by reading a
    /// wrapped result - and lands in `older` or `covered` by that sign, never
    /// `equal`, which an overflowing pair can never actually be.
    private static func delta(minuend: Int64, subtrahend: Int64) -> Int64 {
        let (result, overflowed) = minuend.subtractingReportingOverflow(subtrahend)
        guard overflowed else { return result }
        return minuend >= subtrahend ? Int64.max : Int64.min
    }

    /// `nil` unless both are present - the one place "either field absent"
    /// is decided for the probed-conversation figures, so the two callers in
    /// `probedConversationFigures` cannot disagree about it.
    private static func paired<T>(_ first: T?, _ second: T?, _ combine: (T, T) -> T) -> T? {
        guard let first, let second else { return nil }
        return combine(first, second)
    }

    private static func formattedMicroseconds(_ value: Int64?) -> String {
        guard let value else { return "n/a" }
        return value >= 0 ? "+\(value) µs" : "\(value) µs"
    }

    private static func formattedAge(_ seconds: Double?) -> String {
        guard let seconds else { return "n/a" }
        return String(format: "%.1f s", seconds)
    }
}
