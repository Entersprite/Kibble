import ChatKit
import Foundation
import GChatBridgeCore

/// The `list_topics` ladder, run against one real conversation - this
/// slice's step 6, and the topics analogue of `APIProbeReport.swift`'s own
/// `paginated_world` ladder section.
///
/// Split into its own file for the same `file_length` reason
/// `LocalBridgeBackend`'s own `+Directory.swift`/`+Errors.swift`/
/// `+SelfIdentification.swift`/`+Capture.swift` already are:
/// `APIProbeReport.swift` was already close to `swiftlint`'s 400-line
/// ceiling.
///
/// **Never a conversation's id, name or members - only which index in the
/// mapped list was chosen.** The same standing rule every other section of
/// this report already follows, because this report is pasted verbatim into
/// a committed file and now describes real conversations.
extension APIProbeReport {
    /// Which conversation to probe. `.mostRecent` is the one with the greatest
    /// `sort_timestamp` (`Conversation.lastActivity`, per `WorldMapping.swift:77-78`)
    /// - the one necessarily just used, since a failing repro needs the
    /// conversation the repro actually happened in, not conversation zero of
    /// whatever order `paginated_world` returned. `nil` sorts lowest, matching
    /// `Conversation.lastActivity`'s own doc comment ("never, or not known
    /// yet" belongs below anything with a timestamp).
    ///
    /// `.mostRecentDirectMessage` is the same over direct messages only: on an
    /// account with a space an app posts into every few minutes, that space
    /// outruns any DM a run was staged in (`findings.md` §52).
    ///
    /// `.index` is world order, which the report never names, so it is only
    /// useful to repeat an earlier run. An index out of range, or a DM choice
    /// with no DM, is reported and falls back to `.mostRecent` rather than
    /// silently picking something the caller did not ask for.
    static func chooseConversationIndex(
        _ conversations: [Conversation],
        choice: ProbeConversation,
        lines: inout [String]
    ) -> Int? {
        switch choice {
        case let .index(override):
            guard conversations.indices.contains(override) else {
                lines.append(
                    "  --probe-conversation=\(override) is out of range "
                        + "(0..<\(conversations.count)) - falling back to most recently active"
                )
                return mostRecentlyActiveIndex(conversations)
            }
            lines.append("  probing conversation index \(override) of \(conversations.count) "
                + "(explicit --probe-conversation)")
            return override
        case .mostRecentDirectMessage:
            if let index = mostRecentlyActiveIndex(conversations, where: { $0.kind == .directMessage }) {
                lines.append("  probing conversation index \(index) of \(conversations.count) "
                    + "(most recently active direct message)")
                return index
            }
            lines
                .append(
                    "  --probe-conversation=dm found no direct message - falling back to most recently active"
                )
            return mostRecentlyActiveIndex(conversations)
        case .mostRecent:
            guard let index = mostRecentlyActiveIndex(conversations) else { return nil }
            lines.append("  probing conversation index \(index) of \(conversations.count) "
                + "(most recently active)")
            return index
        }
    }

    /// The probed conversation's kind - `findings.md` §39.2: a
    /// `read_receipt_set` belongs to one conversation, and two runs that
    /// disagreed about receipts may simply have probed a DM and a space.
    ///
    /// The kind's own `Codable` wire token (`space`, `directMessage`, or an
    /// `.unknown` raw value), which identifies nobody - the same string
    /// ChatKit's wire format carries, rather than a spelling invented here.
    static func conversationKindLine(_ kind: Conversation.Kind) -> String {
        "  probed conversation kind: \(kindWireToken(kind))"
    }

    /// The wire-token spelling on its own, without the report line around it.
    ///
    /// Not `private`: `APIProbeReport+ReadPositions.swift` needs the same
    /// spelling for the read-position histogram's per-kind rows, and this is
    /// the one place that round trip is written - the same "not private, and
    /// the same reason" convention `safeDescription(of:)` already follows in
    /// `APIProbeReport.swift`.
    static func kindWireToken(_ kind: Conversation.Kind) -> String {
        let token = (try? JSONEncoder().encode(kind))
            .flatMap { try? JSONDecoder().decode(String.self, from: $0) }
        return token ?? "not encodable"
    }

    private static func mostRecentlyActiveIndex(
        _ conversations: [Conversation],
        where include: (Conversation) -> Bool = { _ in true }
    ) -> Int? {
        conversations.indices.filter { include(conversations[$0]) }.max { lhs, rhs in
            (conversations[lhs].lastActivity ?? .distantPast)
                < (conversations[rhs].lastActivity ?? .distantPast)
        }
    }

    /// `mapping` is `appendMappingSummary`'s own return value, threaded
    /// through whole rather than split into two parameters - a sixth
    /// parameter here would trip `swiftlint`'s `function_parameter_count`,
    /// and the two only ever travel together anyway: `worldItems` exists
    /// solely to find the one item matching whichever `conversations` entry
    /// `chooseConversationIndex` picks.
    ///
    /// Returns the group it probed, so `appendAttachmentSections` can run
    /// against the same conversation without a sixth parameter here.
    @discardableResult
    static func appendTopicsLadderSection(
        client: ProtoAPIClient,
        mapping: (conversations: [Conversation], worldItems: [WorldItemLite]),
        selfUserID: String?,
        conversation: ProbeConversation,
        lines: inout [String]
    ) async -> GroupId? {
        lines.append("list_topics ladder:")
        let conversations = mapping.conversations
        guard !conversations.isEmpty else {
            lines.append("  no conversation available to probe (empty or failed world mapping)")
            return nil
        }
        guard let index = chooseConversationIndex(
            conversations, choice: conversation, lines: &lines
        ) else {
            lines.append("  no conversation available to probe (empty or failed world mapping)")
            return nil
        }
        let conversation = conversations[index]
        lines.append(conversationKindLine(conversation.kind))
        guard let group = ChannelEventMapping.groupID(for: conversation.id) else {
            // Unreachable in practice: every id in `conversations` came from
            // `ChannelEventMapping.conversationID(_:)` succeeding in the first
            // place, and `groupID(for:)` is its proven inverse. Reported
            // rather than force-unwrapped, the same "unreachable today is not
            // a promise" posture `WorldMapping.kind(for:)` already takes.
            lines.append("  conversation index \(index)'s id could not become a GroupId")
            return nil
        }

        let rungs = TopicsRequestLadder.rungs(for: group)
        let results = await TopicsRequestLadder.run(rungs, with: client)
        lines.append(TopicsRequestLadder.report(results))
        lines.append("")
        appendNestedTopicShapes(results, lines: &lines)
        lines.append("")
        await appendHistoryMappingSummary(
            client: client,
            rung: TopicsRequestLadder.minimumViable(for: group),
            lines: &lines
        )
        lines.append("")
        await appendMentionShapesSection(
            client: client,
            rung: TopicsRequestLadder.minimumViable(for: group),
            lines: &lines
        )
        lines.append("")
        // Rung 4 is the only rung whose request sets `fetch_options:
        // READ_RECEIPTS` (`TopicsRequestLadder.withFetchOptions`) - rungs 1-3
        // never populate `read_receipt_set` at all, so this deliberately does
        // not reuse `minimumViable`'s rung 2.
        await appendReadReceiptsSection(client: client, rung: rungs[3], selfUserID: selfUserID, lines: &lines)
        lines.append("")
        // Session 29's read-position diagnosis: how far this conversation's
        // own read position falls short of its head time, and how far that
        // head time itself falls short of (or past) the newest message this
        // probe can actually load - Cause 1's mechanism, measured rather than
        // inferred. A fifth `list_topics` call on the minimum-viable rung,
        // the same convention `appendHistoryMappingSummary`/
        // `appendMentionShapesSection` already follow.
        await appendProbedReadPositionLine(
            client: client,
            rung: TopicsRequestLadder.minimumViable(for: group),
            conversationID: conversation.id,
            worldItems: mapping.worldItems,
            lines: &lines
        )
        return group
    }

    /// The topics analogue of `appendNestedItemShapes` - `findings.md` has no
    /// entry yet recording which fields inside one `Topic` are populated, the
    /// same gap §20.4 closed for `WorldItemLite`.
    private static func appendNestedTopicShapes(_ results: [TopicsRungResult], lines: inout [String]) {
        lines.append("topic nested shape (field numbers inside each field-1 entry):")
        var any = false
        for result in results {
            guard !result.topicFields.isEmpty else { continue }
            any = true
            lines.append("  \(result.label):")
            for (index, fields) in result.topicFields.enumerated() {
                let rendered = fields
                    .map { "\($0.number):w\($0.wireType)=\($0.byteCount)B" }
                    .joined(separator: " ")
                lines.append("    topic \(index + 1): \(rendered.isEmpty ? "(none)" : rendered)")
            }
        }
        if !any {
            lines.append("  no topics in any rung")
        }
    }

    /// Runs `HistoryMapping` over the minimum-viable rung - a second
    /// `list_topics` call rather than reusing the ladder's own bytes, the
    /// same convention `appendMappingSummary` follows for `paginated_world`:
    /// `TopicsRungResult` deliberately never keeps a typed message or raw
    /// bytes around either. **Counts only** - never message text, a sender
    /// id, or any other value the mapping produced.
    private static func appendHistoryMappingSummary(
        client: ProtoAPIClient,
        rung: TopicsRequestLadder.Rung,
        lines: inout [String]
    ) async {
        lines.append("history mapping summary (list_topics, minimum viable rung):")
        let response: ListTopicsResponse
        do {
            response = try await client.call(.listTopics, rung.request)
        } catch {
            lines.append("  FAILED: \(safeDescription(of: error))")
            return
        }
        let mapped = HistoryMapping.map(response)
        lines.append("  messages: \(mapped.messages.count), skipped: \(mapped.skipped)")
        lines.append(
            "  with non-empty text: \(mapped.messages.count(where: { !$0.text.isEmpty }))"
        )
    }

    /// What the same page carries in the way of annotations - the counts the
    /// mentions spec's two `[Verify]`s wait on (`findings.md` §39.4). One more
    /// `list_topics` call on the minimum-viable rung, for the reason
    /// `appendHistoryMappingSummary`'s doc comment gives: `TopicsRungResult`
    /// keeps no typed message around. The counting and rendering are
    /// `mentionShapes(_:)`/`mentionShapesLines(_:)`, pure and tested.
    ///
    /// A failure is reported through `safeDescription(of:)`, like the sibling
    /// sections: scrubbed to a case, a status or a type name, never an
    /// arbitrary error message.
    private static func appendMentionShapesSection(
        client: ProtoAPIClient,
        rung: TopicsRequestLadder.Rung,
        lines: inout [String]
    ) async {
        lines.append("mention shapes (counts only):")
        let response: ListTopicsResponse
        do {
            response = try await client.call(.listTopics, rung.request)
        } catch {
            lines.append("  FAILED: \(safeDescription(of: error))")
            return
        }
        let messages = response.topics.flatMap(\.replies)
        lines.append(contentsOf: mentionShapesLines(mentionShapes(messages)))
    }

    /// Answers the question this slice exists for: what does Google itself
    /// think our read position is. A third `list_topics` call - `rung` must
    /// be rung 4 (`fetch_options: READ_RECEIPTS`), the only rung whose
    /// request populates `read_receipt_set` (field 6) at all; §21.4 measured
    /// every other rung sending that field back empty. The formatting and
    /// delta arithmetic themselves live in `ReadReceiptReport`, kept pure so
    /// they can be tested against an invented `ReadReceiptSet` with no
    /// network and no account.
    private static func appendReadReceiptsSection(
        client: ProtoAPIClient,
        rung: TopicsRequestLadder.Rung,
        selfUserID: String?,
        lines: inout [String]
    ) async {
        let response: ListTopicsResponse
        do {
            response = try await client.call(.listTopics, rung.request)
        } catch {
            lines.append("read receipts (list_topics rung 4):")
            lines.append("  FAILED: \(safeDescription(of: error))")
            return
        }
        let newestTopic = response.topics.max(by: { $0.createTimeUsec < $1.createTimeUsec })
        let newestTopicReference = newestTopic.map { topic in
            ReadReceiptReport.NewestTopicReference(
                createTimeUsec: topic.createTimeUsec,
                sortTime: topic.hasSortTime ? topic.sortTime : nil,
                newestReplyCreateTime: topic.replies.map(\.createTime).max()
            )
        }
        lines.append(contentsOf: ReadReceiptReport.lines(
            receiptSet: response.readReceiptSet,
            topicCount: response.topics.count,
            newestTopicReference: newestTopicReference,
            selfUserID: selfUserID
        ))
    }
}
