import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// Read state fields 4, 5, 10 and 11 (`findings.md` §64.7), as categories against what the page
/// lists, and the rung 4 and page 500 lines. Written by field number, as the web client's code reads
/// them, because no vendored proto names them yet.
struct ThreadCountsTests {
    /// A topic whose messages are timed as given, oldest first, the first named after the topic.
    private func topic(
        _ id: String, times: [Int64], state: (inout ProbeProtoWriter) -> Void = { _ in }
    ) throws -> GChatBridgeCore.Topic {
        var topic = GChatBridgeCore.Topic()
        topic.id.topicID = id
        topic.replies = times.enumerated().map { index, time in
            var message = GChatBridgeCore.Message()
            message.id.messageID = index == 0 ? id : "\(id)-\(index)"
            message.id.parentID.topicID.topicID = id
            message.createTime = time
            return message
        }
        var writer = ProbeProtoWriter()
        state(&writer)
        topic.topicReadState = try TopicReadState(serializedBytes: writer.data)
        return topic
    }

    private func counts(_ topics: [GChatBridgeCore.Topic]) -> ReadStateCounts {
        var counts = ReadStateCounts()
        for topic in topics {
            counts.count(topic, ordered: topic.replies)
        }
        return counts
    }

    /// A first message at 10 and replies at 20, 30 and 40.
    private let thread: [Int64] = [10, 20, 30, 40]

    @Test func fieldFourIsComparedWithTheRepliesNewerThanTheReadTime() throws {
        let tally = try counts([
            topic("a", times: thread) { $0.int64(2, 25); $0.int64(4, 2) },
            topic("b", times: thread) { $0.int64(2, 5); $0.int64(4, 4) },
            topic("c", times: thread) { $0.int64(2, 25); $0.int64(4, 0) },
            topic("d", times: thread) { $0.int64(2, 45); $0.int64(4, 0) },
            topic("e", times: thread) { $0.int64(2, 25); $0.int64(4, 7) },
            topic("f", times: thread) { $0.int64(2, 25) },
            topic("g", times: thread) { $0.int64(4, 1) }
        ]).unread
        #expect(tally == [
            "equal": 1, "equalWithFirst": 1, "zero": 1, "bothZero": 1, "other": 1, "absent": 1,
            "noReadTime": 1
        ])
    }

    /// A reply exactly at the read time is read (`findings.md` §42).
    @Test func fieldFiveIsComparedWithTheRepliesAtOrBeforeTheReadTime() throws {
        let tally = try counts([
            topic("a", times: thread) { $0.int64(2, 30); $0.int64(5, 2) },
            topic("b", times: thread) { $0.int64(2, 30); $0.int64(5, 3) },
            topic("c", times: thread) { $0.int64(2, 30); $0.int64(5, 9) },
            topic("d", times: thread) { $0.int64(2, 30) },
            topic("e", times: thread) { $0.int64(5, 1) }
        ]).read
        #expect(tally == ["equal": 1, "equalWithFirst": 1, "other": 1, "absent": 1, "noReadTime": 1])
    }

    @Test func fieldTenIsComparedWithTheMessagesListedAndCountedOnSinglesApart() throws {
        let tally = try counts([
            topic("a", times: thread) { $0.int64(10, 4) },
            topic("b", times: thread) { $0.int64(10, 3) },
            topic("c", times: thread) { $0.int64(10, 9) },
            topic("d", times: thread),
            topic("e", times: [10]) { $0.int64(10, 1) },
            topic("f", times: [10])
        ])
        #expect(tally.total == ["equal": 1, "equalReplies": 1, "other": 1, "absent": 1])
        #expect(tally.singleTotal == ["present": 1, "absent": 1])
    }

    /// Counted once per topic; a label with no type is -1; the key is never read.
    @Test func labelTypesAreTalliedOnThreadsAndSinglesApart() throws {
        let tally = try counts([
            topic("a", times: thread) { state in
                state.message(11) { $0.varint(1, 1); $0.bytes(2, Data("key".utf8)) }
                state.message(11) { $0.varint(1, 1) }
            },
            topic("b", times: thread) { $0.message(11) { $0.bytes(2, Data("key".utf8)) } },
            topic("c", times: [10]) { $0.message(11) { $0.varint(1, 2) } }
        ])
        #expect(tally.threadLabels == [1: 1, -1: 1])
        #expect(tally.singleLabels == [2: 1])
    }

    /// The 20-conversation scan feeds the same counts, and prints them under the reply summary.
    @Test func theScanCountsReadStateIntoItsShapes() throws {
        var shapes = ThreadShapes()
        try APIProbeReport.countThreadShapes(
            [topic("a", times: thread) { $0.int64(2, 25); $0.int64(4, 2) }], into: &shapes
        )
        #expect(shapes.readStateCounts.unread == ["equal": 1])
        let text = APIProbeReport.threadShapesLines(shapes).joined(separator: "\n")
        #expect(text.contains("read state 4 (unread) vs replies newer than 2, threads: equal×1"))
    }

    @Test func rungFourLinesCountTopicsThreadsAndFieldTen() throws {
        let lines = try APIProbeReport.rungFourLines([
            topic("a", times: [40, 10, 30, 20]) { $0.int64(10, 4) },
            topic("b", times: [10])
        ])
        #expect(lines.first == "  topics: 2, threads: 1")
        #expect(lines.contains("  read state 10 (total) vs messages listed, threads: equal×1; "
                + "single topics: absent×1"))
    }

    @Test func thePageIsComparedWithWhatListTopicsListed() {
        #expect(APIProbeReport.pageAgainstListedLine(returned: 26, listed: 26)
            == "  page_size 500 against list_topics: 26 returned, 26 listed, the same")
        #expect(APIProbeReport.pageAgainstListedLine(returned: 80, listed: 51).hasSuffix("more returned"))
        #expect(APIProbeReport.pageAgainstListedLine(returned: 0, listed: 3).hasSuffix("fewer returned"))
    }

    /// The sentinel sits in every id, the text and a label's key, lowercase so no masking rule could
    /// be what keeps it out (`CLAUDE.md`).
    @Test func noCountLineCarriesAnIDTextOrLabelKey() throws {
        var thread = try topic("secrettopic", times: [10, 20]) { state in
            state.int64(2, 15)
            state.int64(4, 1)
            state.message(11) { $0.varint(1, 1); $0.bytes(2, Data("secret key".utf8)) }
        }
        thread.replies[0].textBody = "secret words"
        thread.replies[1].creator.userID.id = "secretsender"
        var shapes = ThreadShapes()
        APIProbeReport.countThreadShapes([thread], into: &shapes)
        let text = (APIProbeReport.threadShapesLines(shapes) + APIProbeReport.rungFourLines([thread]))
            .joined(separator: "\n")
        #expect(text.contains("label types (-1 none), threads: 1×1"))
        #expect(!text.contains("secret"))
    }

    /// Built from two counts, so nothing else can reach it; checked with the sentinel all the same.
    @Test func thePageLineIsBuiltFromCountsAlone() {
        var response = ListMessagesResponse()
        response.messages = ["secretfirst", "secretsecond"].map { id in
            var message = GChatBridgeCore.Message()
            message.id.messageID = id
            message.textBody = "secret words"
            return message
        }
        let line = APIProbeReport.pageAgainstListedLine(returned: response.messages.count, listed: 3)
        #expect(line == "  page_size 500 against list_topics: 2 returned, 3 listed, fewer returned")
        #expect(!line.contains("secret"))
    }
}
