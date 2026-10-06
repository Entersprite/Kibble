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
    private let conversations: [Conversation]
    private let historyKeepsThePost: Bool
    private let readyOnConnect: Bool
    private let failsDelete: Bool
    private let stateOnConnect: ConnectionState?
    /// What the newest history page holds, kept in step with the commands.
    private var stored: ChatKit.Message?
    private(set) var commands: [ChatCommand] = []

    static let conversation = Conversation(
        id: Conversation.ID("dm/secret-dm"), kind: .directMessage,
        lastActivity: Date(timeIntervalSince1970: 0)
    )
    static let messageID = ChatKit.Message.ID("secret-message-id")

    init(
        echoes: Bool = true, failsEdit: Bool = false, conversations: [Conversation] = [conversation],
        historyKeepsThePost: Bool = false, readyOnConnect: Bool = true, failsDelete: Bool = false,
        stateOnConnect: ConnectionState? = nil
    ) {
        (events, continuation) = AsyncStream.makeStream()
        self.echoes = echoes
        self.failsEdit = failsEdit
        self.conversations = conversations
        self.historyKeepsThePost = historyKeepsThePost
        self.readyOnConnect = readyOnConnect
        self.failsDelete = failsDelete
        self.stateOnConnect = stateOnConnect
    }

    private func message(localID: String? = nil) -> ChatKit.Message {
        ChatKit.Message(
            id: Self.messageID, conversationID: Self.conversation.id,
            threadID: MessageThread.ID("secret-topic"), sender: ChatKit.Member.ID("secret-user"),
            text: "secretword", createdAt: Date(timeIntervalSince1970: 0), localID: localID
        )
    }

    /// The channel's `SESSION_READY` (type 33), which the bridge routes as
    /// unknown, as the live run saw it.
    func connect() async throws {
        if let stateOnConnect {
            continuation.yield(.connectionStateChanged(stateOnConnect))
        }
        if readyOnConnect {
            continuation.yield(.unknown(type: "googlechat.eventType.33", payload: .null))
        }
    }

    func disconnect() async {}
    func loadConversations() async throws -> [Conversation] {
        conversations
    }

    func loadMessages(
        in _: Conversation.ID,
        before _: ChatKit.Message.ID?
    ) async throws -> [ChatKit.Message] {
        stored.map { [$0] } ?? []
    }

    func setNotificationSetting(_: NotificationLevel, for _: Conversation.ID) async throws {}

    func send(_ command: ChatCommand) async throws {
        commands.append(command)
        try keepHistory(command)
        if echoes {
            echo(command)
        }
    }

    /// What the server keeps, which `loadMessages` answers with.
    private func keepHistory(_ command: ChatCommand) throws {
        switch command {
        case let .sendMessage(_, _, _, localID, _, _) where historyKeepsThePost:
            stored = message(localID: localID)
        case .editMessage:
            if failsEdit {
                throw ChatError.unknown("refused")
            }
            stored?.text = EditProbeReport.editedText
            stored?.editedAt = Date(timeIntervalSince1970: 1)
        case .deleteMessage:
            if failsDelete {
                throw ChatError.decoding("the /api/ delete_message call: empty body")
            }
            stored?.text = ""
            stored?.isDeleted = true
        default:
            break
        }
    }

    /// What the channel would push back.
    private func echo(_ command: ChatCommand) {
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
        #expect(report.contains("8×1"))
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

    /// Review finding 1: the probe never posts anywhere the owner did not
    /// name - no fallback from an index out of range, from `dm` on an account
    /// with no DM, or from an argument it could not read.
    @Test(arguments: [ProbeConversation.index(5), .mostRecentDirectMessage, .mostRecent])
    func anythingButANamedConversationIsRefused(_ choice: ProbeConversation) async {
        let space = Conversation(
            id: Conversation.ID("space/secret-space"), kind: .space,
            lastActivity: Date(timeIntervalSince1970: 0)
        )
        let backend = ScriptedEditBackend(conversations: [space])
        let report = await EditProbeReport.run(backend: backend, conversation: choice, wait: Self.wait)
        #expect(report.contains("refused"))
        #expect(await backend.commands.isEmpty)
    }

    @Test func anIndexInRangeIsUsed() async {
        let backend = ScriptedEditBackend()
        _ = await EditProbeReport.run(backend: backend, conversation: .index(0), wait: Self.wait)
        #expect(await backend.commands.count == 3)
    }

    /// Review finding 2: with no echo, the post is found in history by its
    /// `localID` and deleted anyway.
    @Test func withNoEchoThePostIsFoundInHistoryAndDeleted() async {
        let backend = ScriptedEditBackend(echoes: false, historyKeepsThePost: true)
        let report = await EditProbeReport.run(
            backend: backend, conversation: .mostRecentDirectMessage, wait: Self.wait
        )
        #expect(await backend.commands.last == .deleteMessage(
            id: ScriptedEditBackend.messageID, conversationID: ScriptedEditBackend.conversation.id,
            threadID: MessageThread.ID("secret-topic")
        ))
        #expect(!report.contains("may remain"))
    }

    /// Review finding 2: when cleanup cannot be confirmed, the report says so.
    @Test func whenThePostCannotBeFoundTheReportSaysItMayRemain() async {
        let backend = ScriptedEditBackend(echoes: false)
        let report = await EditProbeReport.run(
            backend: backend, conversation: .mostRecentDirectMessage, wait: Self.wait
        )
        #expect(report.contains("may remain"))
    }

    /// Session 52's live run: the post went out before the channel was
    /// registered, and no echo came. The probe now waits for `SESSION_READY`.
    @Test func itSaysWhetherTheChannelWasReadyBeforePosting() async {
        let ready = await EditProbeReport.run(
            backend: ScriptedEditBackend(), conversation: .mostRecentDirectMessage, wait: Self.wait
        )
        #expect(ready.contains("channel: ready"))
        let backend = ScriptedEditBackend(readyOnConnect: false)
        let notReady = await EditProbeReport.run(
            backend: backend, conversation: .mostRecentDirectMessage, wait: Self.wait
        )
        #expect(notReady.contains("channel: no SESSION_READY"))
        #expect(await backend.commands.count == 3)
    }

    /// With no echo, the copy found in history is edited before it is
    /// deleted, so a missed echo still measures the edit.
    @Test func withNoEchoTheHistoryCopyIsEditedThenDeleted() async throws {
        let backend = ScriptedEditBackend(echoes: false, historyKeepsThePost: true)
        _ = await EditProbeReport.run(
            backend: backend,
            conversation: .mostRecentDirectMessage,
            wait: Self.wait
        )
        let commands = await backend.commands
        try #require(commands.count == 3)
        guard case .editMessage = commands[1], case .deleteMessage = commands[2] else {
            Issue.record("expected post, edit, delete; got \(commands)")
            return
        }
    }

    /// Session 52's second live run: the delete failed and the report said
    /// only "ChatError". The error's kind and the call it names are what the
    /// app's banner shows, so the report shows them too.
    @Test func aFailedDeleteSaysWhy() async {
        let backend = ScriptedEditBackend(failsDelete: true)
        let report = await EditProbeReport.run(
            backend: backend, conversation: .mostRecentDirectMessage, wait: Self.wait
        )
        #expect(report.contains("FAILED: decoding: the /api/ delete_message call: empty body"))
    }

    /// History is read back after each step, so the server's state is known
    /// even when the channel delivers nothing.
    @Test func historyIsReadBackAfterEachStep() async {
        let backend = ScriptedEditBackend(echoes: false, historyKeepsThePost: true)
        let report = await EditProbeReport.run(
            backend: backend, conversation: .mostRecentDirectMessage, wait: Self.wait
        )
        #expect(report.contains("history: text=edited editedAt=present isDeleted=false"))
        #expect(report.contains("history: text=empty editedAt=present isDeleted=true"))
    }

    /// Connection states are reported by kind, never by their detail text.
    @Test func connectionStatesAreReportedWithoutDetail() async {
        let backend = ScriptedEditBackend(
            stateOnConnect: .reconnecting(attempt: 2, issue: nil, detail: "secretdetail")
        )
        let report = await EditProbeReport.run(
            backend: backend, conversation: .mostRecentDirectMessage, wait: Self.wait
        )
        #expect(report.contains("connection: reconnecting attempt 2"))
        #expect(!report.contains("secretdetail"))
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
