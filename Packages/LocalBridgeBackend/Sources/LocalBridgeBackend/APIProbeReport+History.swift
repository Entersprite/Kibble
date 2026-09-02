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
    static func appendTopicsLadderSection(
        client: ProtoAPIClient,
        conversations: [Conversation],
        lines: inout [String]
    ) async {
        lines.append("list_topics ladder:")
        guard let index = conversations.indices.first else {
            lines.append("  no conversation available to probe (empty or failed world mapping)")
            return
        }
        let conversation = conversations[index]
        lines.append("  probing conversation index \(index) of \(conversations.count)")
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
}
