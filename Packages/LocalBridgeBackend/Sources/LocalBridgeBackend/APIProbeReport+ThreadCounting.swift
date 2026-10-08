import Foundation
import GChatBridgeCore
import SwiftProtobuf

/// The thread section's counting (`ThreadShapes`), pure so it can be tested
/// against invented topics. Split from `APIProbeReport+Threads.swift` for
/// `swiftlint`'s `file_length`.
extension APIProbeReport {
    static func countThreadShapes(_ topics: [GChatBridgeCore.Topic], into shapes: inout ThreadShapes) {
        for topic in topics {
            shapes.topics += 1
            shapes.messages += topic.replies.count
            shapes.messagesPerTopic[topic.replies.count, default: 0] += 1
            countQuotes(topic, into: &shapes)
            // `sorted(by:)` is stable, so equal times keep the listed order.
            let ordered = topic.replies.sorted { $0.createTime < $1.createTime }
            if ordered.count > 1 {
                countThread(topic, ordered: ordered, into: &shapes)
                continue
            }
            threadTally(threadFieldNumbers(of: topic), into: &shapes.singleTopicFields)
            if topic.topicReadState.threadCreatedUsec > 0 {
                shapes.threadCreatedSingles += 1
            }
            if let only = ordered.first {
                threadTally(threadFieldNumbers(of: only), into: &shapes.singleMessageFields)
                if only.id.messageID == topic.id.topicID {
                    shapes.singleTopicIDIsMessageID += 1
                }
            }
        }
    }

    private static func countThread(
        _ topic: GChatBridgeCore.Topic,
        ordered: [GChatBridgeCore.Message],
        into shapes: inout ThreadShapes
    ) {
        guard let first = ordered.first, let newest = ordered.last else { return }
        let topicID = topic.id.topicID
        shapes.threads += 1
        threadTally(threadFieldNumbers(of: topic), into: &shapes.threadTopicFields)
        shapes.topicID[topicIDCategory(topicID, ordered: ordered), default: 0] += 1
        if topic.createTimeUsec == first.createTime {
            shapes.topicCreateTimeIsFirstMessage += 1
        }
        let sortTime = if topic.sortTime == newest.createTime {
            "newest"
        } else if topic.sortTime == first.createTime {
            "first"
        } else {
            "other"
        }
        shapes.sortTime[sortTime, default: 0] += 1
        let times = topic.replies.map(\.createTime)
        let order = if times == times.sorted() {
            "ascending"
        } else if times == times.sorted(by: >) {
            "descending"
        } else {
            "other"
        }
        shapes.order[order, default: 0] += 1
        shapes.foreignTopicMessages += topic.replies.count { $0.id.parentID.topicID.topicID != topicID }
        let more = topic.hasContainsMoreUnreadReplies ? String(topic.containsMoreUnreadReplies) : "absent"
        shapes.containsMoreUnreadReplies[more, default: 0] += 1
        if topic.topicReadState.threadCreatedUsec > 0 {
            shapes.threadCreatedThreads += 1
        }
        shapes.threadTopicIDLengths[topicID.utf8.count, default: 0] += 1
        shapes.firstMessageIDLengths[first.id.messageID.utf8.count, default: 0] += 1
        threadTally(threadFieldNumbers(of: first), into: &shapes.firstMessageFields)
        for reply in ordered.dropFirst() {
            shapes.replyIDLengths[reply.id.messageID.utf8.count, default: 0] += 1
            threadTally(threadFieldNumbers(of: reply), into: &shapes.replyFields)
        }
        if ordered.count > shapes.largest?.orderedIDs.count ?? 0 {
            // The first message's own parent, the shape §53.2 measured working
            // for `list_messages`, rather than the topic's id.
            shapes.largest = ThreadShapes.ThreadTarget(
                parent: first.id.parentID, orderedIDs: ordered.map(\.id.messageID)
            )
        }
    }

    private static func topicIDCategory(_ topicID: String, ordered: [GChatBridgeCore.Message]) -> String {
        guard let first = ordered.first?.id.messageID else { return "none" }
        if first == topicID {
            return "first"
        }
        if ordered.dropFirst().contains(where: { $0.id.messageID == topicID }) {
            return "later"
        }
        if !topicID.isEmpty, !first.isEmpty, first.contains(topicID) || topicID.contains(first) {
            return "related"
        }
        return "none"
    }

    private static func countQuotes(_ topic: GChatBridgeCore.Topic, into shapes: inout ThreadShapes) {
        for message in topic.replies where message.hasReplyTo {
            shapes.quoting += 1
            if message.replyTo.id.parentID.topicID.topicID == message.id.parentID.topicID.topicID {
                shapes.quotingOwnTopic += 1
            }
        }
    }

    /// Each thread from the replies-requested call, against the same topic in
    /// the call Kibble's history sends today.
    static func countRungTwo(
        _ rungTwo: [GChatBridgeCore.Topic],
        against threads: [GChatBridgeCore.Topic],
        into shapes: inout ThreadShapes
    ) {
        for thread in threads {
            guard let match = rungTwo.first(where: { $0.id.topicID == thread.id.topicID }) else {
                shapes.rungTwo["missing", default: 0] += 1
                continue
            }
            if match.topicReadState.threadCreatedUsec > 0 {
                shapes.rungTwoMarkedAsThread += 1
            }
            let ordered = thread.replies.sorted { $0.createTime < $1.createTime }.map(\.id.messageID)
            let carried = Set(match.replies.map(\.id.messageID))
            let category = if carried == Set(ordered) {
                "all"
            } else if carried == Set(ordered.prefix(1)) {
                "firstOnly"
            } else if carried == Set(ordered.suffix(1)) {
                "newestOnly"
            } else {
                "other"
            }
            shapes.rungTwo[category, default: 0] += 1
        }
    }

    /// Which end of the thread a page took, and in what order, by position in
    /// `list_topics`' own oldest-first list. Never an id.
    static func pageClassification(returned: [String], ordered: [String]) -> String {
        guard !returned.isEmpty else { return "none" }
        let positions = returned.compactMap { ordered.firstIndex(of: $0) }
        guard positions.count == returned.count else {
            return "\(returned.count - positions.count) of \(returned.count) not on list_topics' page"
        }
        let count = positions.count
        let taken = Set(positions)
        let which = if taken == Set(ordered.indices) {
            "all"
        } else if taken == Set(0 ..< count) {
            "the oldest \(count)"
        } else if taken == Set(ordered.count - count ..< ordered.count) {
            "the newest \(count)"
        } else {
            "\(count) from the middle"
        }
        guard count > 1 else { return which }
        let order = if positions == positions.sorted() {
            "oldest first"
        } else if positions == positions.sorted(by: >) {
            "newest first"
        } else {
            "mixed order"
        }
        return "\(which), \(order)"
    }

    /// The field numbers a message carries, from its bytes, so a field no
    /// vendored proto names still shows (`CLAUDE.md`: believe the walk).
    static func threadFieldNumbers(of message: some SwiftProtobuf.Message) -> Set<Int> {
        guard let bytes: Data = try? message.serializedBytes() else { return [] }
        return Set(ProtoFieldScan.fields(in: bytes).fields.map(\.number))
    }

    static func threadTally(_ numbers: Set<Int>, into counts: inout [Int: Int]) {
        for number in numbers {
            counts[number, default: 0] += 1
        }
    }
}
