import ChatKit
import Foundation
import GChatBridgeCore

/// What threads look like on the wire (threads spike, `findings.md` §63).
/// Google Chat threads are one level deep: a topic holds a first message and
/// its replies. What no run has shown yet is how a thread's first message is
/// told from its replies, what `list_topics` carries for a thread with and
/// without replies requested, and what `list_messages` returns for one.
///
/// **Counts, field numbers, closed vocabularies and world-order indexes
/// only.** The one id kept, `largest`, is used to ask for that thread and is
/// never printed. The counting is `APIProbeReport+ThreadCounting.swift`.
struct ThreadShapes: Equatable {
    /// The thread `list_messages` is asked about: its first message's parent,
    /// and its message ids oldest first. Never printed.
    struct ThreadTarget: Equatable {
        let parent: MessageParentId
        let orderedIDs: [String]
    }

    var conversations = 0
    var failedConversations = 0
    var topics = 0
    var messages = 0
    var messagesPerTopic: [Int: Int] = [:]
    /// Topics with two or more messages.
    var threads = 0
    /// Single-message topics whose id is their message's id.
    var singleTopicIDIsMessageID = 0
    /// A thread's topic id is its first message's id (`first`), a later
    /// message's (`later`), contains or is contained in the first's
    /// (`related`), or none of them (`none`).
    var topicID: [String: Int] = [:]
    var topicCreateTimeIsFirstMessage = 0
    /// A thread's `sort_time` is its newest message's time, its first's, or
    /// neither (`other`).
    var sortTime: [String: Int] = [:]
    /// The order `replies` lists a thread's messages in.
    var order: [String: Int] = [:]
    /// Messages whose own parent names a topic other than the one they came in.
    var foreignTopicMessages = 0
    var containsMoreUnreadReplies: [String: Int] = [:]
    /// Topics with `topic_read_state.thread_created_usec > 0`, which is when
    /// mautrix asks for a topic's replies.
    var threadCreatedSingles = 0
    var threadCreatedThreads = 0
    var threadTopicIDLengths: [Int: Int] = [:]
    var firstMessageIDLengths: [Int: Int] = [:]
    var replyIDLengths: [Int: Int] = [:]
    /// Field numbers present, counted once per topic or message.
    var singleTopicFields: [Int: Int] = [:]
    var threadTopicFields: [Int: Int] = [:]
    var singleMessageFields: [Int: Int] = [:]
    var firstMessageFields: [Int: Int] = [:]
    var replyFields: [Int: Int] = [:]
    /// Messages with `reply_to` (37), Chat's quote reply, and those quoting a
    /// message in their own topic.
    var quoting = 0
    var quotingOwnTopic = 0
    /// What the history request Kibble sends (no `page_size_for_replies`)
    /// carries for each thread: `all`, `firstOnly`, `newestOnly`, `other`,
    /// `missing` or `failed`.
    var rungTwo: [String: Int] = [:]
    /// Of those, topics still marked by `thread_created_usec > 0`.
    var rungTwoMarkedAsThread = 0
    /// Topic field 11, `TopicReadState`, by field number, counted once per topic (§64.4).
    var readStateSingleFields: [Int: Int] = [:]
    var readStateThreadFields: [Int: Int] = [:]
    /// Its sub-message 13, the reply summary. On threads, whether field 1 (total) equals the
    /// replies listed (`equal`), differs (`other`), or the summary is missing (`absent`); on
    /// single-message topics, `absent`, `zero` or `other`.
    var summaryTotal: [String: Int] = [:]
    var summarySingles: [String: Int] = [:]
    /// On threads: field 2 (unread) by value, field 3 (mention kinds) by value, and every summary's
    /// field numbers.
    var summaryUnread: [Int: Int] = [:]
    var summaryMentionKinds: [Int: Int] = [:]
    var summaryFields: [Int: Int] = [:]
    /// On threads, field 4's user ids against the senders: the replies' (`replySenders`), every
    /// message's (`allSenders`), neither (`other`), or no field 4 (`absent`). Never an id.
    var summaryRepliers: [String: Int] = [:]
    /// Read state fields 4, 5, 10 and 11 as categories (`APIProbeReport+ThreadCounts.swift`).
    var readStateCounts = ReadStateCounts()
    /// World field 27 (`flat_threads_enabled`), by conversation kind, over
    /// every conversation.
    var flatThreads: [String: Int] = [:]
    var conversationRows: [String] = []
    var largest: ThreadTarget?
}

extension APIProbeReport {
    /// The staged threads will be in the conversations just used.
    static let threadConversationLimit = 20
    static let threadRepliesPageSize: Int32 = 50

    /// `group` is the probed conversation's, for the rung 4 check.
    static func appendThreadSection(
        client: ProtoAPIClient,
        mapping: (conversations: [Conversation], worldItems: [WorldItemLite]),
        group: GroupId,
        lines: inout [String]
    ) async {
        lines.append("")
        lines.append("thread shapes (counts only; list_topics with page_size_for_replies "
            + "\(threadRepliesPageSize)):")
        let conversations = mapping.conversations
        var shapes = ThreadShapes()
        shapes.flatThreads = flatThreadsTally(conversations.map { conversation in
            (kind: conversation.kind, item: worldItem(for: conversation, in: mapping.worldItems))
        })
        let recent = conversations.indices
            .sorted {
                (conversations[$0].lastActivity ?? .distantPast)
                    > (conversations[$1].lastActivity ?? .distantPast)
            }
            .prefix(threadConversationLimit)
        for index in recent {
            await scanThreads(index: index, mapping: mapping, client: client, into: &shapes)
        }
        lines.append(contentsOf: threadShapesLines(shapes))
        lines.append("")
        await appendRungFourCountCheck(client: client, group: group, lines: &lines)
        lines.append("")
        await appendThreadListMessagesCheck(client: client, target: shapes.largest, lines: &lines)
        lines.append("")
        await appendTopicMetadataCheck(client: client, target: shapes.largest, lines: &lines)
        lines.append("")
        await appendFollowedThreadsSection(client: client, lines: &lines)
    }

    /// One `list_topics` call with replies requested and, when it found a
    /// thread, one more without, to compare the two for the same topics.
    private static func scanThreads(
        index: Int,
        mapping: (conversations: [Conversation], worldItems: [WorldItemLite]),
        client: ProtoAPIClient,
        into shapes: inout ThreadShapes
    ) async {
        let conversation = mapping.conversations[index]
        guard let group = ChannelEventMapping.groupID(for: conversation.id) else {
            shapes.failedConversations += 1
            return
        }
        let historyRequest = TopicsRequestLadder.minimumViable(for: group).request
        var request = historyRequest
        request.pageSizeForReplies = threadRepliesPageSize
        let topics: [GChatBridgeCore.Topic]
        do {
            topics = try await client.call(.listTopics, request).topics
        } catch {
            shapes.failedConversations += 1
            return
        }
        shapes.conversations += 1
        countThreadShapes(topics, into: &shapes)
        let threads = topics.filter { $0.replies.count > 1 }
        guard !threads.isEmpty else { return }
        shapes.conversationRows.append(threadConversationRow(
            index: index,
            conversation: conversation,
            item: worldItem(for: conversation, in: mapping.worldItems),
            threads: threads.count,
            topics: topics.count
        ))
        do {
            let rungTwo = try await client.call(.listTopics, historyRequest)
            countRungTwo(rungTwo.topics, against: threads, into: &shapes)
        } catch {
            shapes.rungTwo["failed", default: 0] += threads.count
        }
    }

    /// `list_messages` on the largest thread found, at the page the bridge will ask for (500, the
    /// thread limit) and at a page of two, to see which end a short page keeps.
    private static func appendThreadListMessagesCheck(
        client: ProtoAPIClient,
        target: ThreadShapes.ThreadTarget?,
        lines: inout [String]
    ) async {
        lines.append("list_messages on the largest thread:")
        guard let target else {
            lines.append("  no thread found - nothing to ask for")
            return
        }
        lines.append("  list_topics carried \(target.orderedIDs.count) messages for it")
        for pageSize: Int32 in [threadMessagesPageSize, 2] {
            var request = ListMessagesRequest()
            request.requestHeader = APIRequestHeader.make()
            request.parentID = target.parent
            request.pageSize = pageSize
            do {
                let response = try await client.call(.listMessages, request)
                lines.append(listMessagesLine(
                    pageSize: pageSize, response: response, ordered: target.orderedIDs
                ))
                if pageSize == threadMessagesPageSize {
                    lines.append(pageAgainstListedLine(
                        returned: response.messages.count, listed: target.orderedIDs.count
                    ))
                }
            } catch {
                lines.append("  page_size \(pageSize): FAILED: \(safeDescription(of: error))")
            }
        }
    }

    static func listMessagesLine(
        pageSize: Int32,
        response: ListMessagesResponse,
        ordered: [String]
    ) -> String {
        var messageFields: [Int: Int] = [:]
        for message in response.messages {
            threadTally(threadFieldNumbers(of: message), into: &messageFields)
        }
        let bytes: Data = (try? response.serializedBytes()) ?? Data()
        var responseFields: [Int: Int] = [:]
        for field in ProtoFieldScan.fields(in: bytes).fields {
            responseFields[field.number, default: 0] += 1
        }
        let returned = response.messages.map(\.id.messageID)
        return "  page_size \(pageSize): \(returned.count) returned, "
            + "\(pageClassification(returned: returned, ordered: ordered)); "
            + "response fields: \(threadNumbered(responseFields)); "
            + "message fields: \(threadNumbered(messageFields))"
    }

    // MARK: - World field 27

    static func flatThreadsTally(
        _ pairs: [(kind: Conversation.Kind, item: WorldItemLite?)]
    ) -> [String: Int] {
        var tally: [String: Int] = [:]
        for pair in pairs {
            tally["\(kindWireToken(pair.kind)) \(flatThreadsValue(pair.item))", default: 0] += 1
        }
        return tally
    }

    static func threadConversationRow(
        index: Int, conversation: Conversation, item: WorldItemLite?, threads: Int, topics: Int
    ) -> String {
        "    index \(index) (\(kindWireToken(conversation.kind))): field 27 \(flatThreadsValue(item)), "
            + "isThreaded \(conversation.isThreaded), threads \(threads) of \(topics) topics"
    }

    private static func flatThreadsValue(_ item: WorldItemLite?) -> String {
        guard let item else { return "unmatched" }
        return item.hasFlatThreadsEnabled ? String(item.flatThreadsEnabled) : "absent"
    }

    private static func worldItem(
        for conversation: Conversation,
        in items: [WorldItemLite]
    ) -> WorldItemLite? {
        items.first { ChannelEventMapping.conversationID($0.groupID) == conversation.id }
    }

    // MARK: - The report

    static func threadShapesLines(_ shapes: ThreadShapes) -> [String] {
        let singles = shapes.messagesPerTopic[1] ?? 0
        var lines = [
            "  conversations scanned: \(shapes.conversations), failed: \(shapes.failedConversations); "
                + "topics: \(shapes.topics), messages: \(shapes.messages)",
            "  messages per topic: \(threadNumbered(shapes.messagesPerTopic))",
            "  world field 27 (flat_threads_enabled) by kind: \(threadNamed(shapes.flatThreads))",
            "  single-message topics named after their message: \(shapes.singleTopicIDIsMessageID) "
                + "of \(singles); with thread_created_usec: \(shapes.threadCreatedSingles)",
            "  threads (topics with 2+ messages): \(shapes.threads)"
        ]
        guard shapes.threads > 0 else {
            lines.append("  no thread found: reply in a thread in a recent conversation and run again")
            lines.append(contentsOf: fieldLines(shapes))
            return lines
        }
        lines.append("  conversations with a thread: \(shapes.conversationRows.count)")
        lines.append(contentsOf: shapes.conversationRows)
        lines.append(contentsOf: [
            "  thread topic id is the message id of: \(threadNamed(shapes.topicID))",
            "  topic create_time_usec is the first message's create_time: "
                + "\(shapes.topicCreateTimeIsFirstMessage) of \(shapes.threads)",
            "  topic sort_time is the create_time of: \(threadNamed(shapes.sortTime))",
            "  replies listed: \(threadNamed(shapes.order)); messages filed under another topic: "
                + "\(shapes.foreignTopicMessages)",
            "  contains_more_unread_replies: \(threadNamed(shapes.containsMoreUnreadReplies)); "
                + "with thread_created_usec: \(shapes.threadCreatedThreads)",
            "  id lengths: topic \(threadNumbered(shapes.threadTopicIDLengths)); "
                + "first message \(threadNumbered(shapes.firstMessageIDLengths)); "
                + "replies \(threadNumbered(shapes.replyIDLengths))",
            "  without page_size_for_replies, the same threads carry: \(threadNamed(shapes.rungTwo)); "
                + "still with thread_created_usec: \(shapes.rungTwoMarkedAsThread)"
        ])
        lines.append(contentsOf: fieldLines(shapes))
        return lines
    }

    private static func fieldLines(_ shapes: ThreadShapes) -> [String] {
        [
            "  topic fields, single: \(threadNumbered(shapes.singleTopicFields)); "
                + "thread: \(threadNumbered(shapes.threadTopicFields))",
            "  message fields, single: \(threadNumbered(shapes.singleMessageFields))",
            "  message fields, first in a thread: \(threadNumbered(shapes.firstMessageFields))",
            "  message fields, replies: \(threadNumbered(shapes.replyFields))",
            "  quote replies (field 37): \(shapes.quoting) of \(shapes.messages) messages, "
                + "quoting their own topic: \(shapes.quotingOwnTopic)"
        ] + readStateLines(shapes)
    }

    static func threadNumbered(_ counts: [Int: Int]) -> String {
        guard !counts.isEmpty else { return "none" }
        return counts.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: " ")
    }

    static func threadNamed(_ counts: [String: Int]) -> String {
        guard !counts.isEmpty else { return "none" }
        return counts.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: " ")
    }
}
