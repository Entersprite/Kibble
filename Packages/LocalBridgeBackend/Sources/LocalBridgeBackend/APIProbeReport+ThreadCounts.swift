import Foundation
import GChatBridgeCore

/// `TopicReadState` fields 4, 5, 10 and 11 (`findings.md` §64.7: 4 and 5 arrived on every topic and
/// were never decoded), each as a closed category against what the same page lists, so one run says
/// which number Kibble can use for a thread's unread count (threads spec §2.2, §4.2). A reply is
/// unread when it is newer than field 2's read time; equal is read (`findings.md` §42). Categories
/// and label type numbers only, never an id, a time or a label's key.
struct ReadStateCounts: Equatable {
    /// Field 4 on threads: `equal` to the replies newer than field 2, `equalWithFirst` to every
    /// message newer than it (when the two differ), `zero` while some reply is newer, `bothZero`
    /// when none is, `other`, `absent`, or `noReadTime` when field 2 is missing.
    var unread: [String: Int] = [:]
    /// Field 5 on threads: `equal` to the replies at or before field 2, `equalWithFirst` to every
    /// message at or before it (when the two differ), `other`, `absent` or `noReadTime`.
    var read: [String: Int] = [:]
    /// Field 10 on threads: `equal` to the messages listed, `equalReplies` to the replies listed,
    /// `other` or `absent`. On single-message topics, `present` or `absent`.
    var total: [String: Int] = [:]
    var singleTotal: [String: Int] = [:]
    /// Field 11's label types (`TopicLabelId` field 1) by number, -1 for a label with none, counted
    /// once per topic.
    var threadLabels: [Int: Int] = [:]
    var singleLabels: [Int: Int] = [:]

    /// One topic, its messages oldest first.
    mutating func count(_ topic: GChatBridgeCore.Topic, ordered: [GChatBridgeCore.Message]) {
        let labels = ThreadRequests.labelTypes(of: topic)
        let totalCount = ThreadRequests.totalCount(of: topic)
        guard ordered.count > 1 else {
            singleTotal[totalCount == nil ? "absent" : "present", default: 0] += 1
            APIProbeReport.threadTally(Set(labels), into: &singleLabels)
            return
        }
        APIProbeReport.threadTally(Set(labels), into: &threadLabels)
        let lastRead = ThreadRequests.lastRead(of: topic)
        let unreadCategory = Self.unreadCategory(
            ThreadRequests.unreadCount(of: topic), lastRead: lastRead, ordered: ordered
        )
        unread[unreadCategory, default: 0] += 1
        let readCategory = Self.readCategory(
            ThreadRequests.readCount(of: topic), lastRead: lastRead, ordered: ordered
        )
        read[readCategory, default: 0] += 1
        total[Self.totalCategory(totalCount, listed: ordered.count), default: 0] += 1
    }

    static func unreadCategory(
        _ value: Int64?, lastRead: Int64?, ordered: [GChatBridgeCore.Message]
    ) -> String {
        guard let value else { return "absent" }
        guard let lastRead else { return "noReadTime" }
        let replies = Int64(ordered.dropFirst().count { $0.createTime > lastRead })
        let all = Int64(ordered.count { $0.createTime > lastRead })
        if value == replies {
            return replies == 0 ? "bothZero" : "equal"
        }
        if value == all {
            return "equalWithFirst"
        }
        return value == 0 ? "zero" : "other"
    }

    static func readCategory(
        _ value: Int64?, lastRead: Int64?, ordered: [GChatBridgeCore.Message]
    ) -> String {
        guard let value else { return "absent" }
        guard let lastRead else { return "noReadTime" }
        let replies = Int64(ordered.dropFirst().count { $0.createTime <= lastRead })
        let all = Int64(ordered.count { $0.createTime <= lastRead })
        if value == replies {
            return "equal"
        }
        return value == all ? "equalWithFirst" : "other"
    }

    /// `listed` counts the first message. A thread longer than the page's replies lists fewer than
    /// it holds, and lands in `other`.
    static func totalCategory(_ value: Int64?, listed: Int) -> String {
        guard let value else { return "absent" }
        if value == Int64(listed) {
            return "equal"
        }
        return value == Int64(listed - 1) ? "equalReplies" : "other"
    }
}

extension APIProbeReport {
    /// A thread longer than this is `[Verify]` (`findings.md` §63.7: up to 500 replies).
    static let threadMessagesPageSize: Int32 = 500

    static func readStateCountLines(_ counts: ReadStateCounts) -> [String] {
        [
            "  read state 4 (unread) vs replies newer than 2, threads: \(threadNamed(counts.unread))",
            "  read state 5 (read) vs replies at or before 2, threads: \(threadNamed(counts.read))",
            "  read state 10 (total) vs messages listed, threads: \(threadNamed(counts.total)); "
                + "single topics: \(threadNamed(counts.singleTotal))",
            "  read state 11 label types (-1 none), threads: \(threadNumbered(counts.threadLabels)); "
                + "single topics: \(threadNumbered(counts.singleLabels))"
        ]
    }

    /// `list_topics` at the ladder's rung 4 (`fetch_options: [USER, TOTAL_MESSAGE_COUNTS,
    /// READ_RECEIPTS]`, replies included) on the probed conversation: whether
    /// `TOTAL_MESSAGE_COUNTS` brings read state field 10 back (threads spec §2.2 moves history to
    /// rung 4 if it does).
    static func appendRungFourCountCheck(
        client: ProtoAPIClient,
        group: GroupId,
        lines: inout [String]
    ) async {
        lines.append("list_topics rung 4 on the probed conversation (does read state 10 come back?):")
        let rung = TopicsRequestLadder.rungs(for: group)[3]
        do {
            let topics = try await client.call(.listTopics, rung.request).topics
            lines.append(contentsOf: rungFourLines(topics))
        } catch {
            lines.append("  FAILED: \(safeDescription(of: error))")
        }
    }

    static func rungFourLines(_ topics: [GChatBridgeCore.Topic]) -> [String] {
        var counts = ReadStateCounts()
        for topic in topics {
            // `sorted(by:)` is stable, so equal times keep the listed order.
            counts.count(topic, ordered: topic.replies.sorted { $0.createTime < $1.createTime })
        }
        let threads = topics.count { $0.replies.count > 1 }
        return ["  topics: \(topics.count), threads: \(threads)"] + readStateCountLines(counts)
    }

    /// What the big page returned against what `list_topics` listed for the same thread, the first
    /// message included in both.
    static func pageAgainstListedLine(returned: Int, listed: Int) -> String {
        let comparison = if returned == listed {
            "the same"
        } else if returned > listed {
            "more returned"
        } else {
            "fewer returned"
        }
        return "  page_size \(threadMessagesPageSize) against list_topics: \(returned) returned, "
            + "\(listed) listed, \(comparison)"
    }
}
