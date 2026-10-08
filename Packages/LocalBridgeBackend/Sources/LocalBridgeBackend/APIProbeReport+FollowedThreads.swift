import Foundation
import GChatBridgeCore

/// Home's Threads list as `paginated_world` answers it (`findings.md` §64.6): top-level field 7,
/// repeated `WorldEntity` `{1: Topic | 3: Message, 2: UserProfile}`. Counts only.
struct FollowedThreadsShape: Equatable {
    var topLevelFields: [Int: Int] = [:]
    /// Inside each `world_section_responses` (field 1).
    var sectionFields: [Int: Int] = [:]
    var entities = 0
    /// Each entity's field numbers, joined: `1+2` is a topic with a profile.
    var entityKinds: [String: Int] = [:]
    var messagesPerTopic: [Int: Int] = [:]
    /// The reply summary's total (`TopicReadState` 13.1) by value, and topics without a summary.
    var summaryTotals: [Int: Int] = [:]
    var topicsWithoutSummary = 0
}

extension APIProbeReport {
    /// `get_user_topic_metadata` on the largest thread the scan found (§64.1), read-only.
    static func appendTopicMetadataCheck(
        client: ProtoAPIClient,
        target: ThreadShapes.ThreadTarget?,
        lines: inout [String]
    ) async {
        lines.append("get_user_topic_metadata on the largest thread:")
        guard let target else {
            lines.append("  no thread found - nothing to ask for")
            return
        }
        let muted = await mutedState(client: client, topic: target.parent.topicID)
        lines.append("  \(muted.line); muted \(muted.text)")
    }

    static func appendFollowedThreadsSection(client: ProtoAPIClient, lines: inout [String]) async {
        lines.append("followed threads (paginated_world as Home's Threads chip sends it):")
        do {
            let raw = try await client.callRaw(
                APIMethod.paginatedWorld.name,
                body: ThreadRequests.followedThreads()
            )
            lines.append("  HTTP \(raw.status), \(raw.body.count) wire bytes")
            lines.append(contentsOf: followedThreadsLines(followedThreadsShape(ThreadRequests.body(raw))))
        } catch {
            lines.append("  FAILED: \(safeDescription(of: error))")
        }
    }

    static func followedThreadsShape(_ body: Data) -> FollowedThreadsShape {
        var shape = FollowedThreadsShape()
        for field in ProtoFieldScan.fields(in: body).fields {
            shape.topLevelFields[field.number, default: 0] += 1
        }
        for section in ProtoFieldScan.payloads(ofField: 1, in: body) {
            for field in ProtoFieldScan.fields(in: section).fields {
                shape.sectionFields[field.number, default: 0] += 1
            }
        }
        for entity in ProtoFieldScan.payloads(ofField: 7, in: body) {
            shape.entities += 1
            let kind = threadFieldNumbers(in: entity).sorted().map(String.init).joined(separator: "+")
            shape.entityKinds[kind, default: 0] += 1
            guard let bytes = ProtoFieldScan.payloads(ofField: 1, in: entity).first,
                  let topic = try? GChatBridgeCore.Topic(serializedBytes: bytes)
            else { continue }
            shape.messagesPerTopic[topic.replies.count, default: 0] += 1
            if let summary = ThreadRequests.summary(of: topic) {
                let total = ProtoFieldScan.varintValues(ofField: 1, in: summary).first ?? 0
                shape.summaryTotals[Int(clamping: total), default: 0] += 1
            } else {
                shape.topicsWithoutSummary += 1
            }
        }
        return shape
    }

    static func followedThreadsLines(_ shape: FollowedThreadsShape) -> [String] {
        [
            "  top-level fields: \(threadNumbered(shape.topLevelFields)); "
                + "section fields: \(threadNumbered(shape.sectionFields))",
            "  entities: \(shape.entities); kinds (field numbers): \(threadNamed(shape.entityKinds))",
            "  messages per topic: \(threadNumbered(shape.messagesPerTopic)); "
                + "reply summary totals: \(threadNumbered(shape.summaryTotals)); "
                + "without a summary: \(shape.topicsWithoutSummary)"
        ]
    }

    // MARK: - Shared by the read and write checks

    /// One raw call, reported as its status and field numbers, or as a scrubbed failure. `body` is
    /// `nil` exactly when the call failed.
    static func threadCall(
        client: ProtoAPIClient,
        method: String,
        body: Data
    ) async -> (body: Data?, line: String) {
        do {
            let raw = try await client.callRaw(method, body: body)
            let decoded = ThreadRequests.body(raw)
            return (decoded, "HTTP \(raw.status), fields \(ThreadRequests.fieldTally(decoded))")
        } catch {
            return (nil, "FAILED: \(safeDescription(of: error))")
        }
    }

    /// `get_user_topic_metadata`'s "is muted" (§64.1).
    struct MutedState {
        let value: Bool?
        /// `true`, `false`, `absent`, or `unread` when the call failed.
        let text: String
        /// The call's own status line.
        let line: String
    }

    static func mutedState(client: ProtoAPIClient, topic: TopicId) async -> MutedState {
        let outcome = await threadCall(
            client: client, method: ThreadRequests.metadataMethod, body: ThreadRequests.metadata(topic)
        )
        guard let body = outcome.body else {
            return MutedState(value: nil, text: "unread", line: outcome.line)
        }
        let value = ThreadRequests.muted(in: body)
        return MutedState(value: value, text: value.map(String.init) ?? "absent", line: outcome.line)
    }
}
