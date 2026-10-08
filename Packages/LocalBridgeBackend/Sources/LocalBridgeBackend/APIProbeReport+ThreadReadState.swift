import Foundation
import GChatBridgeCore

/// Topic field 11, `TopicReadState`, and its reply summary, sub-message 13 (`findings.md` §64.4):
/// what the web client reads for "N replies", the unread badge and the repliers, and what neither
/// vendored proto names. Counts and categories only; the user ids are compared, never kept.
extension APIProbeReport {
    static func countReadState(
        _ topic: GChatBridgeCore.Topic,
        ordered: [GChatBridgeCore.Message],
        into shapes: inout ThreadShapes
    ) {
        let isThread = ordered.count > 1
        shapes.readStateCounts.count(topic, ordered: ordered)
        let fields = threadFieldNumbers(in: ThreadRequests.readState(of: topic))
        if isThread {
            threadTally(fields, into: &shapes.readStateThreadFields)
        } else {
            threadTally(fields, into: &shapes.readStateSingleFields)
        }
        let summary = ThreadRequests.summary(of: topic)
        let total = summary.flatMap { ProtoFieldScan.varintValues(ofField: 1, in: $0).first }
        guard isThread else {
            let single = if summary == nil {
                "absent"
            } else {
                (total ?? 0) == 0 ? "zero" : "other"
            }
            shapes.summarySingles[single, default: 0] += 1
            return
        }
        guard let summary else {
            shapes.summaryTotal["absent", default: 0] += 1
            return
        }
        let category = total == UInt64(ordered.count - 1) ? "equal" : "other"
        shapes.summaryTotal[category, default: 0] += 1
        threadTally(threadFieldNumbers(in: summary), into: &shapes.summaryFields)
        if let unread = ProtoFieldScan.varintValues(ofField: 2, in: summary).first {
            shapes.summaryUnread[Int(clamping: unread), default: 0] += 1
        }
        for kind in ProtoFieldScan.varintValues(ofField: 3, in: summary) {
            shapes.summaryMentionKinds[Int(clamping: kind), default: 0] += 1
        }
        shapes.summaryRepliers[repliersCategory(summary, ordered: ordered), default: 0] += 1
    }

    private static func repliersCategory(_ summary: Data, ordered: [GChatBridgeCore.Message]) -> String {
        let users = ProtoFieldScan.payloads(ofField: 4, in: summary)
        guard !users.isEmpty else { return "absent" }
        let ids = Set(users.compactMap { try? UserId(serializedBytes: $0).id })
        if ids == Set(ordered.dropFirst().map(\.creator.userID.id)) {
            return "replySenders"
        }
        if ids == Set(ordered.map(\.creator.userID.id)) {
            return "allSenders"
        }
        return "other"
    }

    static func threadFieldNumbers(in bytes: Data) -> Set<Int> {
        Set(ProtoFieldScan.fields(in: bytes).fields.map(\.number))
    }

    static func readStateLines(_ shapes: ThreadShapes) -> [String] {
        [
            "  read state (topic field 11) fields, single: \(threadNumbered(shapes.readStateSingleFields)); "
                + "thread: \(threadNumbered(shapes.readStateThreadFields))",
            "  reply summary (11.13): total vs replies listed, threads \(threadNamed(shapes.summaryTotal)); "
                + "single topics \(threadNamed(shapes.summarySingles))",
            "  reply summary on threads: fields \(threadNumbered(shapes.summaryFields)); "
                + "unread \(threadNumbered(shapes.summaryUnread)); "
                + "mention kinds \(threadNumbered(shapes.summaryMentionKinds)); "
                + "user ids vs senders \(threadNamed(shapes.summaryRepliers))"
        ] + readStateCountLines(shapes.readStateCounts)
    }
}
