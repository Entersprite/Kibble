import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// Topic field 11, `TopicReadState`, and its reply summary (sub-message 13, `findings.md` §64.4),
/// which neither vendored proto names. Counts and categories only.
struct ThreadReadStateTests {
    private func message(
        _ id: String, topic: String, at time: Int64, from sender: String
    ) -> GChatBridgeCore.Message {
        var message = GChatBridgeCore.Message()
        message.id.messageID = id
        message.id.parentID.topicID.topicID = topic
        message.createTime = time
        message.creator.userID.id = sender
        return message
    }

    private func userID(_ id: String) -> Data {
        var user = UserId()
        user.id = id
        return ThreadRequests.bytes(of: user)
    }

    /// A summary with `total`, `unread`, mention kinds and user ids, written by field number as the
    /// web client's code reads it.
    private func summary(
        total: UInt64?, unread: UInt64? = nil, kinds: [UInt64] = [], users: [String]? = nil
    ) -> (inout ProbeProtoWriter) -> Void {
        { writer in
            if let total {
                writer.varint(1, total)
            }
            if let unread {
                writer.varint(2, unread)
            }
            for kind in kinds {
                writer.varint(3, kind)
            }
            for user in users ?? [] {
                writer.bytes(4, userID(user))
            }
        }
    }

    private func topic(
        _ id: String,
        senders: [String],
        summary: ((inout ProbeProtoWriter) -> Void)? = nil,
        lastRead: Int64? = nil,
        markedUnread: Int64? = nil
    ) throws -> GChatBridgeCore.Topic {
        var topic = GChatBridgeCore.Topic()
        topic.id.topicID = id
        topic.replies = senders.enumerated().map { index, sender in
            message(index == 0 ? id : "\(id)-\(index)", topic: id, at: Int64(index + 1), from: sender)
        }
        var state = ProbeProtoWriter()
        if let lastRead {
            state.int64(2, lastRead)
        }
        if let summary {
            state.message(13, summary)
        }
        if let markedUnread {
            state.int64(14, markedUnread)
        }
        topic.topicReadState = try TopicReadState(serializedBytes: state.data)
        return topic
    }

    @Test func aThreadsSummaryTotalIsComparedWithTheRepliesListed() throws {
        var shapes = ThreadShapes()
        try APIProbeReport.countThreadShapes([
            topic("a", senders: ["p", "q", "r"], summary: summary(total: 2)),
            topic("b", senders: ["p", "q"], summary: summary(total: 5)),
            topic("c", senders: ["p", "q"])
        ], into: &shapes)
        #expect(shapes.summaryTotal == ["equal": 1, "other": 1, "absent": 1])
    }

    @Test func aSingleTopicsSummaryIsAbsentZeroOrOther() throws {
        var shapes = ThreadShapes()
        try APIProbeReport.countThreadShapes([
            topic("a", senders: ["p"]),
            topic("b", senders: ["p"], summary: summary(total: 0)),
            topic("c", senders: ["p"], summary: summary(total: 3))
        ], into: &shapes)
        #expect(shapes.summarySingles == ["absent": 1, "zero": 1, "other": 1])
    }

    @Test func unreadCountsMentionKindsAndSummaryFieldsAreTallied() throws {
        var shapes = ThreadShapes()
        try APIProbeReport.countThreadShapes([
            topic("a", senders: ["p", "q"], summary: summary(total: 1, unread: 1, kinds: [1, 2])),
            topic("b", senders: ["p", "q"], summary: summary(total: 1, unread: 0))
        ], into: &shapes)
        #expect(shapes.summaryUnread == [1: 1, 0: 1])
        #expect(shapes.summaryMentionKinds == [1: 1, 2: 1])
        #expect(shapes.summaryFields == [1: 2, 2: 2, 3: 1])
    }

    @Test func theSummarysUserIdsAreComparedWithTheSenders() throws {
        var shapes = ThreadShapes()
        try APIProbeReport.countThreadShapes([
            topic("a", senders: ["p", "q", "r"], summary: summary(total: 2, users: ["r", "q"])),
            topic("b", senders: ["p", "q"], summary: summary(total: 1, users: ["p", "q"])),
            topic("c", senders: ["p", "q"], summary: summary(total: 1, users: ["x"])),
            topic("d", senders: ["p", "q"], summary: summary(total: 1))
        ], into: &shapes)
        #expect(shapes.summaryRepliers == [
            "replySenders": 1, "allSenders": 1, "other": 1, "absent": 1
        ])
    }

    @Test func readStateFieldsAreTalliedForSinglesAndThreadsApart() throws {
        var shapes = ThreadShapes()
        try APIProbeReport.countThreadShapes([
            topic("a", senders: ["p"], lastRead: 5),
            topic("b", senders: ["p", "q"], summary: summary(total: 1), lastRead: 5, markedUnread: 4)
        ], into: &shapes)
        #expect(shapes.readStateSingleFields == [2: 1])
        #expect(shapes.readStateThreadFields == [2: 1, 13: 1, 14: 1])
    }

    @Test func theReadersFindLastReadMarkedUnreadAndTheUnreadCount() throws {
        let thread = try topic(
            "a", senders: ["p", "q"], summary: summary(total: 1, unread: 1), lastRead: 7, markedUnread: 6
        )
        #expect(ThreadRequests.lastRead(of: thread) == 7)
        #expect(ThreadRequests.markedUnread(of: thread) == 6)
        #expect(ThreadRequests.unreadReplies(of: thread) == 1)
        let bare = try topic("b", senders: ["p"])
        #expect(ThreadRequests.lastRead(of: bare) == nil)
        #expect(ThreadRequests.markedUnread(of: bare) == nil)
        #expect(ThreadRequests.unreadReplies(of: bare) == nil)
    }

    /// The sentinel sits in every id, user id and topic id, lowercase (`CLAUDE.md`).
    @Test func noReadStateLineCarriesAnID() throws {
        var shapes = ThreadShapes()
        try APIProbeReport.countThreadShapes([
            topic(
                "secrettopic", senders: ["secretsender", "secretreplier"],
                summary: summary(total: 1, unread: 1, users: ["secretreplier"]), lastRead: 3
            )
        ], into: &shapes)
        let text = APIProbeReport.threadShapesLines(shapes).joined(separator: "\n")
        #expect(text.contains("reply summary"))
        #expect(!text.contains("secret"))
    }
}
