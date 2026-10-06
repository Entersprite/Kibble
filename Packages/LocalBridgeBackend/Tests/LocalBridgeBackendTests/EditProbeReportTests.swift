import ChatKit
import Foundation
import Testing
@testable import LocalBridgeBackend

/// A backend that answers the probe the way the channel would: an echo of the
/// post carrying its `localID`, an update for the edit, a tombstone for the
/// delete. Its message text is a lowercase sentinel, which the report must
/// never print (CLAUDE.md: a leak test's sentinel must be one a masker would
/// let through).
private actor ScriptedEditBackend: ChatBackend {
    nonisolated let capabilities = Capabilities(
        canSendMessages: true, canEditMessages: true, canDeleteMessages: true
    )
    nonisolated let events: AsyncStream<ChatEvent>
    private let continuation: AsyncStream<ChatEvent>.Continuation
    private let echoes: Bool
    private let failsEdit: Bool
    private(set) var commands: [ChatCommand] = []

    static let conversation = Conversation(
        id: Conversation.ID("dm/secret-dm"), kind: .directMessage,
        lastActivity: Date(timeIntervalSince1970: 0)
    )
    static let messageID = ChatKit.Message.ID("secret-message-id")

    init(echoes: Bool = true, failsEdit: Bool = false) {
        (events, continuation) = AsyncStream.makeStream()
        self.echoes = echoes
        self.failsEdit = failsEdit
    }

    func connect() async throws {}
    func disconnect() async {}
    func loadConversations() async throws -> [Conversation] {
        [Self.conversation]
    }

    func loadMessages(
        in _: Conversation.ID,
        before _: ChatKit.Message.ID?
    ) async throws -> [ChatKit.Message] {
        []
    }

    func setNotificationSetting(_: NotificationLevel, for _: Conversation.ID) async throws {}

    func send(_ command: ChatCommand) async throws {
        commands.append(command)
        if failsEdit, case .editMessage = command {
            throw ChatError.unknown("refused")
        }
        guard echoes else { return }
        var message = ChatKit.Message(
            id: Self.messageID, conversationID: Self.conversation.id,
            threadID: MessageThread.ID("secret-topic"), sender: ChatKit.Member.ID("secret-user"),
            text: "secretword", createdAt: Date(timeIntervalSince1970: 0)
        )
        switch command {
        case let .sendMessage(_, _, _, localID, _, _):
            message.localID = localID
            continuation.yield(.messageReceived(message))
        case .editMessage:
            message.text = EditProbeReport.editedText
            message.editedAt = Date(timeIntervalSince1970: 1)
            continuation.yield(.messageUpdated(message))
        case .deleteMessage:
            message.text = ""
            message.isDeleted = true
            continuation.yield(.messageUpdated(message))
            continuation.yield(.unknown(type: "googlechat.eventType.8", payload: .null))
        default:
            break
        }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct EditProbeReportTests {
    private static let wait = Duration.milliseconds(300)

    @Test func withoutAConversationItRefusesAndSendsNothing() async {
        let backend = ScriptedEditBackend()
        let report = await EditProbeReport.run(backend: backend, conversation: nil, wait: Self.wait)
        #expect(report.contains("--probe-conversation"))
        #expect(await backend.commands.isEmpty)
    }

    @Test func itPostsEditsAndDeletesInOrder() async throws {
        let backend = ScriptedEditBackend()
        _ = await EditProbeReport.run(
            backend: backend,
            conversation: .mostRecentDirectMessage,
            wait: Self.wait
        )
        let commands = await backend.commands
        try #require(commands.count == 3)
        guard case let .sendMessage(conversation, nil, text, _, _, _) = commands[0] else {
            Issue.record("expected a post first, got \(commands[0])")
            return
        }
        #expect(conversation == ScriptedEditBackend.conversation.id)
        #expect(text == EditProbeReport.probeText)
        #expect(commands[1] == .editMessage(
            id: ScriptedEditBackend.messageID, text: EditProbeReport.editedText,
            conversationID: ScriptedEditBackend.conversation.id, threadID: MessageThread.ID("secret-topic")
        ))
        #expect(commands[2] == .deleteMessage(
            id: ScriptedEditBackend.messageID, conversationID: ScriptedEditBackend.conversation.id,
            threadID: MessageThread.ID("secret-topic")
        ))
    }

    @Test func theReportNamesEventKindsNotContent() async {
        let report = await EditProbeReport.run(
            backend: ScriptedEditBackend(), conversation: .mostRecentDirectMessage, wait: Self.wait
        )
        #expect(report.contains("messageUpdated editedAt=present text=edited isDeleted=false"))
        #expect(report.contains("isDeleted=true"))
        #expect(report.contains("unknown event types: 8×1"))
        for secret in ["secretword", "secret-message-id", "secret-dm", "secret-topic", "secret-user"] {
            #expect(!report.contains(secret), "\(secret) leaked")
        }
    }

    /// Guard: a post that echoed is deleted even when the edit fails, so a run
    /// leaves no test message behind.
    @Test func aFailedEditStillDeletesThePost() async {
        let backend = ScriptedEditBackend(failsEdit: true)
        let report = await EditProbeReport.run(
            backend: backend, conversation: .mostRecentDirectMessage, wait: Self.wait
        )
        #expect(report.contains("FAILED"))
        let last = await backend.commands.last
        guard case .deleteMessage = last else {
            Issue.record("expected the post deleted last, got \(String(describing: last))")
            return
        }
    }

    /// Guard: no echo, no edit - and the run ends within its wait.
    @Test func aMissingEchoStopsTheRunWithinTheWait() async {
        let backend = ScriptedEditBackend(echoes: false)
        let started = ContinuousClock.now
        let report = await EditProbeReport.run(
            backend: backend, conversation: .mostRecentDirectMessage, wait: Self.wait
        )
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(report.contains("no echo"))
        #expect(await backend.commands.count == 1)
    }
}
