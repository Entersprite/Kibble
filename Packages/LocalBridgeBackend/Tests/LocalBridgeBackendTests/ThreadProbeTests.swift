import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// The probe's thread section (threads spike): how a thread's first message is
/// told from its replies, as counts, and nothing that could carry an id or text.
struct ThreadProbeTests {
    private func message(_ id: String, topic: String, at time: Int64) -> GChatBridgeCore.Message {
        var message = GChatBridgeCore.Message()
        message.id.messageID = id
        message.id.parentID.topicID.topicID = topic
        message.id.parentID.topicID.groupID.spaceID.spaceID = "s-1"
        message.createTime = time
        return message
    }

    private func topic(
        _ id: String, created: Int64, sort: Int64, _ messages: [GChatBridgeCore.Message]
    ) -> GChatBridgeCore.Topic {
        var topic = GChatBridgeCore.Topic()
        topic.id.topicID = id
        topic.id.groupID.spaceID.spaceID = "s-1"
        topic.createTimeUsec = created
        topic.sortTime = sort
        topic.replies = messages
        return topic
    }

    /// A topic whose messages are timed 1, 2, 3… in the order given.
    private func thread(_ id: String, _ messageIDs: [String]) -> GChatBridgeCore.Topic {
        let messages = messageIDs.enumerated().map { message($1, topic: id, at: Int64($0 + 1)) }
        return topic(id, created: 1, sort: Int64(messageIDs.count), messages)
    }

    /// One single-message topic named after its message and one that is not;
    /// a thread named after its first message, sorted by its newest and listed
    /// oldest first; and a thread named after none of its messages, sorted by
    /// its first and listed newest first.
    private var page: [GChatBridgeCore.Topic] {
        [
            topic("a", created: 10, sort: 10, [message("a", topic: "a", at: 10)]),
            topic("b", created: 20, sort: 20, [message("b-1", topic: "b", at: 20)]),
            topic("c", created: 30, sort: 50, [
                message("c", topic: "c", at: 30),
                message("c-2", topic: "c", at: 40),
                message("c-3", topic: "c", at: 50)
            ]),
            topic("d", created: 60, sort: 60, [
                message("q", topic: "d", at: 70),
                message("p", topic: "d", at: 60)
            ])
        ]
    }

    @Test func itTellsThreadsFromSingleMessagesAndCountsHowEachIsNamed() {
        var shapes = ThreadShapes()
        APIProbeReport.countThreadShapes(page, into: &shapes)
        #expect(shapes.topics == 4)
        #expect(shapes.messages == 7)
        #expect(shapes.messagesPerTopic == [1: 2, 2: 1, 3: 1])
        #expect(shapes.threads == 2)
        #expect(shapes.singleTopicIDIsMessageID == 1)
        #expect(shapes.topicID == ["first": 1, "none": 1])
        #expect(shapes.topicCreateTimeIsFirstMessage == 2)
        #expect(shapes.sortTime == ["newest": 1, "first": 1])
        #expect(shapes.order == ["ascending": 1, "descending": 1])
        #expect(shapes.foreignTopicMessages == 0)
        #expect(shapes.containsMoreUnreadReplies == ["absent": 2])
    }

    @Test func aTopicIDInsideTheFirstMessageIDIsRelatedAndALaterOneIsLater() {
        var shapes = ThreadShapes()
        APIProbeReport.countThreadShapes([thread("e", ["e.e", "x"]), thread("f", ["y", "f"])], into: &shapes)
        #expect(shapes.topicID == ["related": 1, "later": 1])
    }

    /// A message filed under a topic whose own parent names another topic.
    @Test func aMessageWhoseOwnTopicIsNotItsTopicsIsCounted() {
        var foreign = thread("g", ["g"])
        foreign.replies.append(message("z-1", topic: "z", at: 2))
        var shapes = ThreadShapes()
        APIProbeReport.countThreadShapes([foreign], into: &shapes)
        #expect(shapes.foreignTopicMessages == 1)
    }

    /// mautrix asks for a topic's replies when read state 2 (its `thread_created_usec`) is above 0
    /// (`APIMethod.listMessages`' doc comment): counted on threads and on
    /// single-message topics apart, since a thread whose replies were not
    /// requested looks like a single one.
    @Test func aThreadCreatedTimeIsCountedOnThreadsAndSinglesApart() {
        var pageWithTimes = page
        pageWithTimes[1].topicReadState.lastReadTime = 20
        pageWithTimes[2].topicReadState.lastReadTime = 30
        pageWithTimes[3].topicReadState.lastReadTime = 0
        var shapes = ThreadShapes()
        APIProbeReport.countThreadShapes(pageWithTimes, into: &shapes)
        #expect(shapes.threadCreatedSingles == 1)
        #expect(shapes.threadCreatedThreads == 1)
    }

    /// Field numbers, per message, in three tallies - a field only replies
    /// carry is exactly what tells a reply apart on a push.
    @Test func messageFieldsAreTalliedForSinglesFirstMessagesAndRepliesApart() {
        var shapes = ThreadShapes()
        APIProbeReport.countThreadShapes(page, into: &shapes)
        // Every invented message carries `id` (1) and `create_time` (3) only.
        #expect(shapes.singleMessageFields == [1: 2, 3: 2])
        #expect(shapes.firstMessageFields == [1: 2, 3: 2])
        #expect(shapes.replyFields == [1: 3, 3: 3])
        // Topics carry `id` (1), `sort_time` (2), `replies` (7) and
        // `create_time_usec` (15).
        #expect(shapes.singleTopicFields == [1: 2, 2: 2, 7: 2, 15: 2])
        #expect(shapes.threadTopicFields == [1: 2, 2: 2, 7: 2, 15: 2])
    }

    /// `num_unread_replies` (9) is named and lands in the first message's
    /// tally; field 45 (purple's `request_reply_in_thread`) is named by no
    /// vendored proto and must still show, on the reply that carries it.
    /// Field 45, wire type 0: tag `(45 << 3) | 0 = 360`, two varint bytes.
    @Test func aNamedSummaryFieldAndAnUnnamedReplyFieldBothShow() throws {
        var first = message("h", topic: "h", at: 1)
        first.numUnreadReplies = 2
        var reply = try GChatBridgeCore.Message(serializedBytes: Data([0xE8, 0x02, 0x01]))
        reply.id.messageID = "h-2"
        reply.id.parentID.topicID.topicID = "h"
        reply.createTime = 2
        var shapes = ThreadShapes()
        APIProbeReport.countThreadShapes([topic("h", created: 1, sort: 2, [reply, first])], into: &shapes)
        #expect(shapes.firstMessageFields[9] == 1)
        #expect(shapes.replyFields[45] == 1)
        #expect(shapes.firstMessageFields[45] == nil)
    }

    /// Counted once per message, however many times a repeated field occurs.
    @Test func aRepeatedFieldCountsOncePerMessage() {
        var single = message("i", topic: "i", at: 1)
        single.annotations = [GChatBridgeCore.Annotation(), GChatBridgeCore.Annotation()]
        single.annotations[0].startIndex = 0
        single.annotations[1].startIndex = 1
        var shapes = ThreadShapes()
        APIProbeReport.countThreadShapes([topic("i", created: 1, sort: 1, [single])], into: &shapes)
        #expect(shapes.singleMessageFields[11] == 1)
    }

    @Test func theLargestThreadIsKeptWithItsMessagesInTimeOrder() {
        var shapes = ThreadShapes()
        APIProbeReport.countThreadShapes(page, into: &shapes)
        #expect(shapes.largest?.orderedIDs == ["c", "c-2", "c-3"])
        #expect(shapes.largest?.parent.topicID.topicID == "c")
        var later = ThreadShapes()
        APIProbeReport.countThreadShapes(Array(page.suffix(1)), into: &later)
        #expect(later.largest?.orderedIDs == ["p", "q"])
    }

    @Test func aQuoteReplyIsCountedAndSoIsWhetherItQuotesItsOwnTopic() {
        var quoting = message("j-2", topic: "j", at: 2)
        quoting.replyTo.id.messageID = "j"
        quoting.replyTo.id.parentID.topicID.topicID = "j"
        var elsewhere = message("k", topic: "k", at: 3)
        elsewhere.replyTo.id.messageID = "j"
        elsewhere.replyTo.id.parentID.topicID.topicID = "j"
        var shapes = ThreadShapes()
        APIProbeReport.countThreadShapes([
            topic("j", created: 1, sort: 2, [message("j", topic: "j", at: 1), quoting]),
            topic("k", created: 3, sort: 3, [elsewhere])
        ], into: &shapes)
        #expect(shapes.quoting == 2)
        #expect(shapes.quotingOwnTopic == 1)
    }

    // MARK: - What the default request carries for the same threads

    @Test func withoutRepliesRequestedEachThreadIsClassifiedByWhatItCarries() {
        let threads = [
            thread("c", ["c", "c-2", "c-3"]), thread("d", ["d", "d-2"]), thread("e", ["e", "e-2"]),
            thread("f", ["f", "f-2"]), thread("g", ["g", "g-2"])
        ]
        // Only ids decide what a topic carries; `g` is missing.
        var rungTwo = [
            thread("c", ["c"]),
            thread("d", ["d-2"]),
            thread("e", ["e", "e-2"]),
            thread("f", ["f-9"])
        ]
        rungTwo[0].topicReadState.lastReadTime = 1
        var shapes = ThreadShapes()
        APIProbeReport.countRungTwo(rungTwo, against: threads, into: &shapes)
        #expect(shapes.rungTwo == ["firstOnly": 1, "newestOnly": 1, "all": 1, "other": 1, "missing": 1])
        // Whether the default request can still tell these topics are threads.
        #expect(shapes.rungTwoMarkedAsThread == 1)
    }

    // MARK: - list_messages on one thread

    @Test func aPageIsDescribedByWhichEndOfTheThreadItTookAndInWhatOrder() {
        let ordered = ["1", "2", "3"]
        #expect(APIProbeReport.pageClassification(returned: ["1", "2", "3"], ordered: ordered)
            == "all, oldest first")
        #expect(APIProbeReport.pageClassification(returned: ["3", "2", "1"], ordered: ordered)
            == "all, newest first")
        #expect(APIProbeReport.pageClassification(returned: ["1", "2"], ordered: ordered)
            == "the oldest 2, oldest first")
        #expect(APIProbeReport.pageClassification(returned: ["3", "2"], ordered: ordered)
            == "the newest 2, newest first")
        #expect(APIProbeReport.pageClassification(returned: ["2", "3"], ordered: ordered)
            == "the newest 2, oldest first")
        #expect(APIProbeReport.pageClassification(returned: ["2"], ordered: ordered) == "1 from the middle")
        #expect(APIProbeReport.pageClassification(returned: ["1", "3", "2"], ordered: ordered)
            == "all, mixed order")
        #expect(APIProbeReport.pageClassification(returned: [], ordered: ordered) == "none")
        #expect(APIProbeReport.pageClassification(returned: ["1", "9"], ordered: ordered)
            == "1 of 2 not on list_topics' page")
    }

    @Test func aListMessagesLineCountsMessagesAndFieldsAndNamesNothing() {
        var response = ListMessagesResponse()
        response.messages = [
            message("secretfirst", topic: "secrettopic", at: 1),
            message("secretsecond", topic: "secrettopic", at: 2)
        ]
        response.messages[0].textBody = "secret text"
        let line = APIProbeReport.listMessagesLine(
            pageSize: 2, response: response, ordered: ["secretfirst", "secretsecond", "secretthird"]
        )
        #expect(line == "  page_size 2: 2 returned, the oldest 2, oldest first; "
            + "response fields: 1×2; message fields: 1×2 3×2 10×1")
        #expect(!line.contains("secret"))
    }

    // MARK: - World field 27 and the per-conversation rows

    @Test func fieldTwentySevenIsTalliedByKindAndPresence() {
        var on = WorldItemLite()
        on.inlineThreadingEnabled = true
        var off = WorldItemLite()
        off.inlineThreadingEnabled = false
        let tally = APIProbeReport.flatThreadsTally([
            (kind: .directMessage, item: on),
            (kind: .directMessage, item: on),
            (kind: .space, item: off),
            (kind: .space, item: WorldItemLite()),
            (kind: .space, item: nil)
        ])
        #expect(tally == [
            "directMessage true": 2, "space false": 1, "space absent": 1, "space unmatched": 1
        ])
    }

    @Test func aConversationRowCarriesItsIndexKindAndCountsOnly() {
        let conversation = Conversation(
            id: Conversation.ID(rawValue: "dm/secretconversation"), kind: .directMessage,
            title: "secret title", isThreaded: false
        )
        var item = WorldItemLite()
        item.inlineThreadingEnabled = true
        let row = APIProbeReport.threadConversationRow(
            index: 4, conversation: conversation, item: item, threads: 2, topics: 50
        )
        #expect(row == "    index 4 (directMessage): field 27 true, isThreaded false, threads 2 of 50 topics")
    }

    // MARK: - The report

    /// The sentinel sits in every id, every text and the topic ids, lowercase
    /// so no masking rule could be what keeps it out (`CLAUDE.md`).
    @Test func noLineCarriesAnIDOrText() {
        var first = message("secretmessage", topic: "secrettopic", at: 1)
        first.textBody = "secret words"
        var reply = message("secretreply", topic: "secrettopic", at: 2)
        reply.replyTo.id.messageID = "secretmessage"
        reply.replyTo.textBody = "secret quoted"
        var shapes = ThreadShapes()
        APIProbeReport.countThreadShapes(
            [topic("secrettopic", created: 1, sort: 2, [first, reply])], into: &shapes
        )
        shapes.flatThreads = ["directMessage true": 1]
        let text = APIProbeReport.threadShapesLines(shapes).joined(separator: "\n")
        #expect(text.contains("threads (topics with 2+ messages): 1"))
        #expect(!text.contains("secret"))
    }

    @Test func aRunWithNoThreadSaysWhatToDo() {
        var shapes = ThreadShapes()
        APIProbeReport.countThreadShapes(
            [topic("a", created: 1, sort: 1, [message("a", topic: "a", at: 1)])],
            into: &shapes
        )
        let lines = APIProbeReport.threadShapesLines(shapes)
        #expect(lines.contains("  no thread found: reply in a thread in a recent conversation and run again"))
    }
}
