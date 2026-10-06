import ChatKit
import Foundation

/// `--probe=edit`: posts one message into a conversation the owner names,
/// edits it, deletes it, and reports what came back (edit spec §3).
///
/// **It drives `LocalBridgeBackend` itself**, so a run measures the code that
/// ships, and it reads the answers as the domain events the app will see:
/// whether the edit arrived as an update carrying `editedAt`, and whether the
/// delete arrived as a tombstone, as `MESSAGE_DELETED`, or both.
///
/// **A conversation is required.** A post is visible to the conversation's
/// members, so the probe never picks one by itself.
///
/// **Kinds and flags, never content.** Text is reported only as which of the
/// probe's own two strings it matches; no id, name or wire text is printed.
public enum EditProbeReport {
    public static let probeText = "Kibble edit probe"
    public static let editedText = "Kibble edit probe (edited)"

    static let title = "gchat edit probe (posts one message, edits it, deletes it)"

    static let refusal = [
        title, "",
        "refused: pass --probe-conversation=dm or =N. A post is visible to the "
            + "conversation's members, so this probe never picks one by itself."
    ].joined(separator: "\n")

    /// Every parameter but `conversation` defaults, so `MacHost` names no core
    /// type.
    public static func run(
        store: KeychainCredentialStore = KeychainCredentialStore(),
        conversation: ProbeConversation?
    ) async -> String {
        guard conversation != nil else { return refusal }
        let backend: LocalBridgeBackend?
        do {
            backend = try await LocalBridgeBackend.using(store)
        } catch {
            return [title, "", "keychain: \(APIProbeReport.safeDescription(of: error))"]
                .joined(separator: "\n")
        }
        guard let backend else {
            return [title, "", "no session in the Keychain - sign in first"].joined(separator: "\n")
        }
        let report = await run(backend: backend, conversation: conversation, wait: .seconds(20))
        await backend.disconnect()
        return report
    }

    static func run(
        backend: any ChatBackend,
        conversation: ProbeConversation?,
        wait: Duration
    ) async -> String {
        guard let conversation else { return refusal }
        var lines = [title, ""]
        let log = EventLog()
        let listener = Task {
            for await event in backend.events {
                await log.append(event)
            }
        }
        defer { listener.cancel() }
        guard let target = await connect(backend, choosing: conversation, lines: &lines) else {
            return lines.joined(separator: "\n")
        }
        await exercise(backend, in: target, log: log, wait: wait, lines: &lines)
        lines.append("")
        await lines.append("unknown event types: " + (log.unknownTally()))
        return lines.joined(separator: "\n")
    }

    private static func connect(
        _ backend: any ChatBackend,
        choosing choice: ProbeConversation,
        lines: inout [String]
    ) async -> Conversation? {
        let conversations: [Conversation]
        do {
            try await backend.connect()
            conversations = try await backend.loadConversations()
        } catch {
            lines.append("connect FAILED: \(APIProbeReport.safeDescription(of: error))")
            return nil
        }
        lines.append("conversation:")
        guard let index = namedIndex(choice, in: conversations) else {
            lines.append("  refused: --probe-conversation= names no conversation here (an index out of "
                + "range, dm with no direct message, or an argument this probe cannot read). It never "
                + "falls back to another conversation.")
            return nil
        }
        lines.append("  posting into conversation index \(index) of \(conversations.count)")
        lines.append(APIProbeReport.conversationKindLine(conversations[index].kind))
        lines.append("")
        return conversations[index]
    }

    /// The conversation the owner named, or `nil`: unlike the read-only
    /// probes' chooser, never a fallback, because this one posts (review
    /// finding 1). `dm` is the most recently active direct message.
    static func namedIndex(_ choice: ProbeConversation, in conversations: [Conversation]) -> Int? {
        switch choice {
        case let .index(index):
            conversations.indices.contains(index) ? index : nil
        case .mostRecentDirectMessage:
            conversations.indices
                .filter { conversations[$0].kind == .directMessage }
                .max {
                    (conversations[$0].lastActivity ?? .distantPast) <
                        (conversations[$1].lastActivity ?? .distantPast)
                }
        case .mostRecent:
            nil
        }
    }

    /// Post, edit, delete. A post that echoed is always deleted, whatever the
    /// edit did, so a run leaves nothing behind it can help.
    private static func exercise(
        _ backend: any ChatBackend,
        in conversation: Conversation,
        log: EventLog,
        wait: Duration,
        lines: inout [String]
    ) async {
        let localID = "kibble-edit-probe-\(UUID().uuidString)"
        lines.append("post:")
        do {
            try await backend.send(.sendMessage(
                conversationID: conversation.id, threadID: nil, text: probeText, localID: localID
            ))
            lines.append("  accepted")
        } catch {
            lines.append("  FAILED: \(APIProbeReport.safeDescription(of: error))")
            return
        }
        let posted = await log.first(within: wait) { event -> ChatKit.Message? in
            if case let .messageReceived(message) = event, message.localID == localID {
                return message
            }
            return nil
        }
        guard let posted else {
            lines.append("  no echo within \(wait); not editing")
            lines += await cleanUp(localID: localID, in: conversation, backend: backend, log: log, wait: wait)
            return
        }
        lines.append("  echo: messageReceived text=\(textClass(posted.text))")
        lines += await step("edit", of: posted, log: log, wait: wait) {
            try await backend.send(.editMessage(
                id: posted.id, text: editedText,
                conversationID: posted.conversationID, threadID: posted.threadID
            ))
        }
        let deleted = await step("delete", of: posted, log: log, wait: wait) {
            try await backend.send(.deleteMessage(
                id: posted.id, conversationID: posted.conversationID, threadID: posted.threadID
            ))
        }
        lines += deleted
        if deleted.contains(where: { $0.contains("FAILED") }) {
            lines.append(mayRemain)
        }
    }

    static let mayRemain = "WARNING: the test message may remain in that conversation; delete it by hand."

    /// With no echo the post may still have landed: find it in the newest
    /// history page by its `localID` and delete it, or say that it may remain
    /// (review finding 2).
    private static func cleanUp(
        localID: String,
        in conversation: Conversation,
        backend: any ChatBackend,
        log: EventLog,
        wait: Duration
    ) async -> [String] {
        let page = try? await backend.loadMessages(in: conversation.id, before: nil)
        guard let found = page?.first(where: { $0.localID == localID }) else {
            return ["  not found in the newest history page", mayRemain]
        }
        var lines = ["  found in history"]
        let deleted = await step("delete", of: found, log: log, wait: wait) {
            try await backend.send(.deleteMessage(
                id: found.id, conversationID: found.conversationID, threadID: found.threadID
            ))
        }
        lines += deleted
        if deleted.contains(where: { $0.contains("FAILED") }) {
            lines.append(mayRemain)
        }
        return lines
    }

    /// One command, then every event naming the message until a quiet moment
    /// after the first, or `wait` with none.
    private static func step(
        _ name: String,
        of message: ChatKit.Message,
        log: EventLog,
        wait: Duration,
        _ perform: () async throws -> Void
    ) async -> [String] {
        var lines = ["\(name):"]
        let start = await log.count
        do {
            try await perform()
            lines.append("  accepted")
        } catch {
            lines.append("  FAILED: \(APIProbeReport.safeDescription(of: error))")
            return lines
        }
        let seen = await log.naming(message.id, after: start, within: wait)
        if seen.isEmpty {
            lines.append("  no event for the message within \(wait)")
        }
        lines.append(contentsOf: seen.map { "  " + describe($0) })
        return lines
    }

    static func describe(_ event: ChatEvent) -> String {
        switch event {
        case let .messageUpdated(message):
            "messageUpdated editedAt=\(message.editedAt == nil ? "absent" : "present") "
                + "text=\(textClass(message.text)) isDeleted=\(message.isDeleted)"
        case let .messageReceived(message):
            "messageReceived text=\(textClass(message.text)) isDeleted=\(message.isDeleted)"
        case .messageDeleted:
            "messageDeleted"
        default:
            "other"
        }
    }

    /// Which of the probe's own strings a text is - never the text.
    static func textClass(_ text: String) -> String {
        switch text {
        case probeText: "original"
        case editedText: "edited"
        case "": "empty"
        default: "other"
        }
    }
}

/// Every event the backend emitted during the run, in order.
private actor EventLog {
    private var events: [ChatEvent] = []

    var count: Int {
        events.count
    }

    func append(_ event: ChatEvent) {
        events.append(event)
    }

    /// Polls in 100 ms steps, bounded by `wait` (CLAUDE.md: no task-group race).
    func first<Value>(within wait: Duration, _ match: (ChatEvent) -> Value?) async -> Value? {
        let deadline = ContinuousClock.now + wait
        while true {
            if let found = events.lazy.compactMap(match).first {
                return found
            }
            guard ContinuousClock.now < deadline else { return nil }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// The events naming `id` since `start`: waits for the first, then for a
    /// quiet moment, so a delete answered twice (update and tombstone) is
    /// reported twice.
    func naming(_ id: ChatKit.Message.ID, after start: Int, within wait: Duration) async -> [ChatEvent] {
        let relevant = { (event: ChatEvent) -> Bool in
            switch event {
            case let .messageUpdated(message), let .messageReceived(message): message.id == id
            case let .messageDeleted(deleted, _): deleted == id
            default: false
            }
        }
        let found = await first(within: wait) { event in relevant(event) ? true : nil }
        guard found != nil else { return [] }
        try? await Task.sleep(for: min(.seconds(2), wait))
        return events.dropFirst(start).filter(relevant)
    }

    /// `googlechat.eventType.N` counted by N, so a `MESSAGE_DELETED` the
    /// mapping could not read still shows.
    func unknownTally() -> String {
        var counts: [String: Int] = [:]
        for case let .unknown(type, _) in events {
            counts[type.replacingOccurrences(of: "googlechat.eventType.", with: ""), default: 0] += 1
        }
        guard !counts.isEmpty else { return "none" }
        return counts.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: ", ")
    }
}
