import Foundation
import GChatBridgeCore

/// The thread whose state the write round trips change and restore: the most recently active
/// thread in the conversation `--probe-conversation=` names, its address, and its newest
/// message's time. Never printed.
struct ThreadWriteTarget {
    let topic: TopicId
    let newestMicros: Int64
    let state: GChatBridgeCore.Topic
}

/// `--probe-thread-writes` (`findings.md` §64): follow, mark unread and mark read, each read back.
/// Opt-in, and refused unless the conversation was named, because each step changes the owner's
/// account. Follow and unread are restored; mark read is not, since reading a test thread is the
/// state it ends in anyway.
extension APIProbeReport {
    static func appendThreadWriteRoundTrips(
        client: ProtoAPIClient,
        group: GroupId?,
        conversation: ProbeConversation,
        lines: inout [String]
    ) async {
        lines.append("thread write round trips (--probe-thread-writes):")
        defer { lines.append("") }
        guard conversation != .mostRecent else {
            lines.append("  refused: name the conversation with --probe-conversation=dm or =N")
            return
        }
        guard let group,
              let topics = await threadTopics(client: client, group: group),
              let target = threadWriteTarget(in: topics)
        else {
            lines.append("  no thread in the probed conversation - reply in a thread there and rerun")
            return
        }
        let lastRead = ThreadRequests.readBack(
            ThreadRequests.lastRead(of: target.state), sent: target.newestMicros
        )
        let markedUnread = ThreadRequests.markedUnread(of: target.state) == nil ? "absent" : "present"
        lines.append(
            "  target: the most recently active thread, \(target.state.replies.count) messages; before: "
                + "11.2 \(lastRead), 11.14 \(markedUnread), unread replies \(unreadText(target.state))"
        )
        await appendFollowRoundTrip(client: client, topic: target.topic, lines: &lines)
        await appendUnreadRoundTrip(client: client, group: group, target: target, lines: &lines)
        await appendMarkRead(client: client, group: group, target: target, lines: &lines)
    }

    /// The thread with the latest `sort_time`, which is its newest message's time (§63.4).
    static func threadWriteTarget(in topics: [GChatBridgeCore.Topic]) -> ThreadWriteTarget? {
        let threads = topics.filter { $0.replies.count > 1 }
        guard let latest = threads.max(by: { $0.sortTime < $1.sortTime }) else { return nil }
        let ordered = latest.replies.sorted { $0.createTime < $1.createTime }
        guard let first = ordered.first, let newest = ordered.last else { return nil }
        // The first message's own parent: the address §53.2 measured `list_messages` accepting.
        return ThreadWriteTarget(
            topic: first.id.parentID.topicID,
            newestMicros: newest.createTime,
            state: latest
        )
    }

    private static func appendFollowRoundTrip(
        client: ProtoAPIClient,
        topic: TopicId,
        lines: inout [String]
    ) async {
        let before = await mutedState(client: client, topic: topic)
        let original = before.value ?? false
        let set = await setMuted(client: client, topic: topic, mute: !original)
        let afterSet = await mutedState(client: client, topic: topic)
        let restore = await threadCall(
            client: client, method: set.method, body: ThreadRequests.muteState(topic, mute: original)
        )
        let afterRestore = await mutedState(client: client, topic: topic)
        lines.append("  follow: muted before \(before.text); set \(!original): \(set.line); "
            + "read back \(afterSet.text)")
        lines.append("  restore \(original) via \(set.method): \(restore.line); "
            + "read back \(afterRestore.text)")
    }

    /// The web client's spelling first; the lowercase one only if that is refused (§64.1).
    private static func setMuted(
        client: ProtoAPIClient, topic: TopicId, mute: Bool
    ) async -> (method: String, line: String) {
        let body = ThreadRequests.muteState(topic, mute: mute)
        let first = await threadCall(client: client, method: ThreadRequests.muteMethod, body: body)
        let firstLine = "\(ThreadRequests.muteMethod) \(first.line)"
        guard first.body == nil else { return (ThreadRequests.muteMethod, firstLine) }
        let second = await threadCall(client: client, method: ThreadRequests.lowercaseMuteMethod, body: body)
        let method = second.body == nil ? ThreadRequests.muteMethod : ThreadRequests.lowercaseMuteMethod
        return (method, "\(firstLine); \(ThreadRequests.lowercaseMuteMethod) \(second.line)")
    }

    private static func appendUnreadRoundTrip(
        client: ProtoAPIClient, group: GroupId, target: ThreadWriteTarget, lines: inout [String]
    ) async {
        // "Mark as unread" on the newest message sends its time minus 1 µs (§64.3).
        let sent = target.newestMicros - 1
        let marked = await threadCall(
            client: client, method: ThreadRequests.unreadMethod,
            body: ThreadRequests.topicTime(target.topic, micros: sent)
        )
        let afterMark = await readBack(client: client, group: group, topic: target.topic)
        let cleared = await threadCall(
            client: client, method: ThreadRequests.unreadMethod,
            body: ThreadRequests.topicTime(target.topic, micros: 0)
        )
        let afterClear = await readBack(client: client, group: group, topic: target.topic)
        let markedBack = ThreadRequests.readBack(
            afterMark.flatMap(ThreadRequests.markedUnread(of:)), sent: sent
        )
        let clearedBack = ThreadRequests.readBack(
            afterClear.flatMap(ThreadRequests.markedUnread(of:)), sent: 0
        )
        lines.append("  mark unread (newest - 1 µs): \(marked.line); read back 11.14 \(markedBack), "
            + "unread replies \(unreadText(afterMark))")
        lines.append("  clear (0): \(cleared.line); read back 11.14 \(clearedBack), "
            + "unread replies \(unreadText(afterClear))")
    }

    private static func appendMarkRead(
        client: ProtoAPIClient, group: GroupId, target: ThreadWriteTarget, lines: inout [String]
    ) async {
        let sent = target.newestMicros
        let marked = await threadCall(
            client: client, method: ThreadRequests.markReadMethod,
            body: ThreadRequests.topicTime(target.topic, micros: sent)
        )
        let after = await readBack(client: client, group: group, topic: target.topic)
        let readTime = ThreadRequests.readBack(after.flatMap(ThreadRequests.lastRead(of:)), sent: sent)
        lines.append("  mark read (newest): \(marked.line); read back 11.2 \(readTime), "
            + "unread replies \(unreadText(after))")
    }

    /// The probed conversation's newest page, replies included: the target and every read-back.
    private static func threadTopics(
        client: ProtoAPIClient,
        group: GroupId
    ) async -> [GChatBridgeCore.Topic]? {
        var request = TopicsRequestLadder.minimumViable(for: group).request
        request.pageSizeForReplies = threadRepliesPageSize
        return try? await client.call(.listTopics, request).topics
    }

    /// The target topic again, a second after a write, so the read is not racing it.
    private static func readBack(
        client: ProtoAPIClient, group: GroupId, topic: TopicId
    ) async -> GChatBridgeCore.Topic? {
        try? await Task.sleep(for: .seconds(1))
        return await threadTopics(client: client, group: group)?.first { $0.id.topicID == topic.topicID }
    }

    private static func unreadText(_ topic: GChatBridgeCore.Topic?) -> String {
        guard let topic else { return "topic not found" }
        return ThreadRequests.unreadReplies(of: topic).map(String.init) ?? "absent"
    }
}
