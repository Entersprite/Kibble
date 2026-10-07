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

    static let title = "kibble edit probe (posts one message, edits it, deletes it)"

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
        lines += await log.connectionLines()
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
        // `connect()` starts the long poll without awaiting it, and session
        // 52's first run posted before the channel was registered: no echo.
        let ready = await log.first(within: wait) { event -> Bool? in
            if case let .unknown(type, _) = event, type == ChannelEventMapping.discriminator(for: 33) {
                return true
            }
            return nil
        }
        lines.append(ready == nil
            ? "channel: no SESSION_READY within \(wait); posting anyway"
            : "channel: ready (SESSION_READY seen)")
        let localID = "kibble-edit-probe-\(UUID().uuidString)"
        lines.append("post:")
        do {
            try await backend.send(.sendMessage(
                conversationID: conversation.id, threadID: nil, text: probeText, localID: localID
            ))
            lines.append("  accepted")
        } catch {
            lines.append("  FAILED: \(failure(error))")
            return
        }
        let (found, report) = await posted(
            localID: localID,
            in: conversation,
            backend: backend,
            log: log,
            wait: wait
        )
        lines += report
        guard let posted = found else { return }
        lines += await step("edit", of: posted, log: log, wait: wait) {
            try await backend.send(.editMessage(
                id: posted.id, text: editedText,
                conversationID: posted.conversationID, threadID: posted.threadID
            ))
        }
        await lines.append(history(of: posted, backend: backend))
        let deleted = await step("delete", of: posted, log: log, wait: wait) {
            try await backend.send(.deleteMessage(
                id: posted.id, conversationID: posted.conversationID, threadID: posted.threadID
            ))
        }
        lines += deleted
        await lines.append(history(of: posted, backend: backend))
        if deleted.contains(where: { $0.contains("FAILED") }) {
            lines.append(mayRemain)
        }
    }

    /// The message as the newest history page holds it now: the server's
    /// state, read without the channel (session 52's second run had none).
    static func history(of message: ChatKit.Message, backend: any ChatBackend) async -> String {
        guard let page = try? await backend.loadMessages(in: message.conversationID, before: nil) else {
            return "  history: could not load"
        }
        guard let found = page.first(where: { $0.id == message.id }) else {
            return "  history: absent from the newest page"
        }
        let edited = found.editedAt == nil ? "absent" : "present"
        return "  history: text=\(textClass(found.text)) editedAt=\(edited) isDeleted=\(found.isDeleted)"
    }

    /// A failure as the app's banner would name it: the error's kind and the
    /// call it names, both built by this package from safe parts
    /// (`chatError(fromAPI:call:)`).
    static func failure(_ error: any Error) -> String {
        guard let error = error as? ChatError else { return APIProbeReport.safeDescription(of: error) }
        return switch error {
        case let .transport(message): "transport: \(message)"
        case let .decoding(message): "decoding: \(message)"
        case let .server(status, message): "server \(status): \(message)"
        case let .unknown(message): "unknown: \(message)"
        case let .unsupported(capability): "unsupported: \(capability)"
        case .notAuthenticated: "not authenticated"
        case .sessionExpired: "session expired"
        case .rateLimited: "rate limited"
        case .signInRequired: "sign-in required"
        }
    }

    /// A connection state by kind; a detail string is never printed.
    static func state(_ state: ConnectionState) -> String {
        switch state {
        case .idle: "idle"
        case .connecting: "connecting"
        case .connected: "connected"
        case let .reconnecting(attempt, issue, _): "reconnecting attempt \(attempt)" + issueText(issue)
        case let .disconnected(_, issue): "disconnected" + issueText(issue)
        case .unknown: "unknown"
        }
    }

    private static func issueText(_ issue: ConnectionIssue?) -> String {
        switch issue {
        case nil: ""
        case .unknown?: " (unknown issue)"
        case let issue?: " (\(issue))"
        }
    }

    static let mayRemain = "WARNING: the test message may remain in that conversation; delete it by hand."

    /// The post as the channel echoed it, or - with no echo - as the newest
    /// history page holds it, found by its `localID` (review finding 2). `nil`
    /// when neither has it, and the report then says it may remain.
    private static func posted(
        localID: String,
        in conversation: Conversation,
        backend: any ChatBackend,
        log: EventLog,
        wait: Duration
    ) async -> (ChatKit.Message?, [String]) {
        let echoed = await log.first(within: wait) { event -> ChatKit.Message? in
            if case let .messageReceived(message) = event, message.localID == localID {
                return message
            }
            return nil
        }
        if let echoed {
            return (echoed, ["  echo: messageReceived text=\(textClass(echoed.text))"])
        }
        var lines = ["  no echo within \(wait)"]
        let page = try? await backend.loadMessages(in: conversation.id, before: nil)
        guard let found = page?.first(where: { $0.localID == localID }) else {
            return (nil, lines + ["  not found in the newest history page", mayRemain])
        }
        lines.append("  found in history: text=\(textClass(found.text))")
        return (found, lines)
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
            lines.append("  FAILED: \(failure(error))")
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

    /// Every connection state and backend error, in order, by kind.
    func connectionLines() -> [String] {
        events.compactMap { event in
            switch event {
            case let .connectionStateChanged(state): "connection: " + EditProbeReport.state(state)
            case let .backendError(error): "backend error: " + EditProbeReport.failure(error)
            default: nil
            }
        }
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
