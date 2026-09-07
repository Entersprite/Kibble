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
    /// Which conversation to probe: the one with the greatest `sort_timestamp`
    /// (`Conversation.lastActivity`, per `WorldMapping.swift:77-78`) - the one
    /// necessarily just used, since a failing repro needs the conversation the
    /// repro actually happened in, not conversation zero of whatever order
    /// `paginated_world` returned. `nil` sorts lowest, matching
    /// `Conversation.lastActivity`'s own doc comment ("never, or not known
    /// yet" belongs below anything with a timestamp).
    ///
    /// `override` is `--probe-conversation=N`, threaded down from
    /// `APIProbeReport.run(conversationIndexOverride:)`. An out-of-range
    /// override is reported and falls back to the same most-recently-active
    /// choice rather than silently picking something the caller did not ask
    /// for.
    static func chooseConversationIndex(
        _ conversations: [Conversation],
        override: Int?,
        lines: inout [String]
    ) -> Int? {
        if let override {
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
        }
        guard let index = mostRecentlyActiveIndex(conversations) else { return nil }
        lines.append("  probing conversation index \(index) of \(conversations.count) "
            + "(most recently active)")
        return index
    }

    private static func mostRecentlyActiveIndex(_ conversations: [Conversation]) -> Int? {
        conversations.indices.max { lhs, rhs in
            (conversations[lhs].lastActivity ?? .distantPast)
                < (conversations[rhs].lastActivity ?? .distantPast)
        }
    }

    static func appendTopicsLadderSection(
        client: ProtoAPIClient,
        conversations: [Conversation],
        selfUserID: String?,
        conversationIndexOverride: Int?,
        lines: inout [String]
    ) async {
        lines.append("list_topics ladder:")
        guard !conversations.isEmpty else {
            lines.append("  no conversation available to probe (empty or failed world mapping)")
            return
        }
        guard let index = chooseConversationIndex(
            conversations, override: conversationIndexOverride, lines: &lines
        ) else {
            lines.append("  no conversation available to probe (empty or failed world mapping)")
            return
        }
        let conversation = conversations[index]
        guard let group = ChannelEventMapping.groupID(for: conversation.id) else {
            // Unreachable in practice: every id in `conversations` came from
            // `ChannelEventMapping.conversationID(_:)` succeeding in the first
            // place, and `groupID(for:)` is its proven inverse. Reported
            // rather than force-unwrapped, the same "unreachable today is not
            // a promise" posture `WorldMapping.kind(for:)` already takes.
            lines.append("  conversation index \(index)'s id could not become a GroupId")
            return
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
        // Rung 4 is the only rung whose request sets `fetch_options:
        // READ_RECEIPTS` (`TopicsRequestLadder.withFetchOptions`) - rungs 1-3
        // never populate `read_receipt_set` at all, so this deliberately does
        // not reuse `minimumViable`'s rung 2.
        await appendReadReceiptsSection(client: client, rung: rungs[3], selfUserID: selfUserID, lines: &lines)
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
