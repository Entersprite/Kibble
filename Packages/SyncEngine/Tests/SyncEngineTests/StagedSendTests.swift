import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import SyncEngine

/// Files staged in the composer: per conversation, uploaded in turn, each
/// sent as its own message with the text on the first, and handed back when
/// anything is refused.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct StagedSendTests {
    private static func file(_ id: String, byteSize: Int = 100) -> OutgoingAttachment {
        OutgoingAttachment(
            id: id, file: URL(fileURLWithPath: "/nonexistent/\(id).png"), name: "\(id).png",
            contentType: "image/png", byteSize: byteSize, width: 40, height: 30
        )
    }

    private static func model(
        _ backend: RecordingBackend
    ) async throws -> (ChatSessionModel, Conversation.ID) {
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let model = ChatSessionModel(store: store, engine: engine, me: nil, markReadDebounce: .zero)
        try await model.start()
        await settleAutoMarkRead()
        let conversation = FixtureWorld.minimal.messages[0].conversationID
        model.select(conversation)
        await settleAutoMarkRead()
        return (model, conversation)
    }

    private static func sends(_ backend: RecordingBackend) async -> [ChatCommand] {
        await backend.commands.filter {
            if case .sendMessage = $0 {
                true
            } else {
                false
            }
        }
    }

    @Test func aStagedFileIsUploadedThenSentWithTheText() async throws {
        let backend = RecordingBackend()
        let (model, conversation) = try await Self.model(backend)
        model.stage([Self.file("a")])
        #expect(model.stagedAttachments.map(\.id) == ["a"])

        model.send("caption")
        await settleAutoMarkRead(until: "the staged file has gone") { model.stagedAttachments.isEmpty }

        #expect(await backend.uploads.map(\.id) == ["a"])
        let sent = await Self.sends(backend)
        guard case let .sendMessage(sentTo, _, text, _, attachments)? = sent.first else {
            Issue.record("expected one sendMessage")
            return
        }
        #expect(sent.count == 1)
        #expect(sentTo == conversation)
        #expect(text == "caption")
        #expect(attachments.map(\.name) == ["a.png"])
        await settleAutoMarkRead(until: "the echo carries the attachment") {
            model.messages.contains { $0.attachments.map(\.name) == ["a.png"] && $0.text == "caption" }
        }
        await model.stop()
    }

    @Test func twoFilesAreTwoMessagesInOrderWithTheTextOnTheFirst() async throws {
        let backend = RecordingBackend()
        let (model, _) = try await Self.model(backend)
        model.stage([Self.file("a"), Self.file("b")])
        model.send("hello")
        await settleAutoMarkRead(until: "both sent") { model.stagedAttachments.isEmpty }

        let sent = await Self.sends(backend)
        let shapes = sent.compactMap { command -> String? in
            guard case let .sendMessage(_, _, text, _, attachments) = command else { return nil }
            return "\(text)|\(attachments.map(\.name).joined())"
        }
        #expect(shapes == ["hello|a.png", "|b.png"])
        await model.stop()
    }

    /// A file staged twice is staged once, and a file over the limit is
    /// refused with a banner rather than uploaded.
    @Test func duplicatesAndOversizedFilesAreNotStaged() async throws {
        let backend = RecordingBackend()
        let (model, _) = try await Self.model(backend)
        model.stage([Self.file("a"), Self.file("a")])
        model.stage([Self.file("huge", byteSize: OutgoingAttachment.maximumByteSize + 1)])
        #expect(model.stagedAttachments.map(\.id) == ["a"])
        await settleAutoMarkRead(until: "the oversize banner") { model.lastError != nil }
        await model.stop()
    }

    @Test func stagedFilesBelongToTheirConversation() async throws {
        let backend = RecordingBackend()
        let (model, first) = try await Self.model(backend)
        model.stage([Self.file("a")])
        let other = try #require(model.conversations.first { $0.id != first })
        model.select(other.id)
        #expect(model.stagedAttachments.isEmpty)
        model.select(first)
        #expect(model.stagedAttachments.map(\.id) == ["a"])
        await model.stop()
    }

    @Test func aRefusedUploadMarksTheFileFailedAndHandsTheTextBack() async throws {
        let backend = RecordingBackend()
        let (model, _) = try await Self.model(backend)
        model.stage([Self.file("a"), Self.file("b")])
        await backend.failUploads(true)
        model.send("caption")
        await settleAutoMarkRead(until: "the send stopped") {
            model.stagedAttachments.allSatisfy { !$0.isUploading }
        }

        #expect(model.stagedAttachments.map(\.state) == [.failed, .ready])
        #expect(await Self.sends(backend).isEmpty)
        #expect(model.failedDraft == "caption")
        #expect(model.lastError != nil)

        // Send tries the failed one again.
        await backend.failUploads(false)
        model.send("")
        await settleAutoMarkRead(until: "both sent") { model.stagedAttachments.isEmpty }
        #expect(await Self.sends(backend).count == 2)
        await model.stop()
    }

    /// The upload worked and the message was refused: the file is kept, the
    /// text comes back, and the optimistic row is retracted.
    @Test func aRefusedMessageKeepsTheFile() async throws {
        let backend = RecordingBackend()
        let (model, conversation) = try await Self.model(backend)
        model.stage([Self.file("a")])
        await backend.failSubmissions(true)
        model.send("caption")
        await settleAutoMarkRead(until: "the send stopped") {
            model.stagedAttachments.allSatisfy { !$0.isUploading }
        }
        #expect(model.stagedAttachments.map(\.state) == [.failed])
        #expect(model.failedDraft == "caption")
        let rows = try model.store.messages(in: conversation)
        #expect(!rows.contains { $0.id.rawValue.hasPrefix("local/") })
        await model.stop()
    }

    /// Once the first file's message is posted its text is gone from the
    /// composer, so a later failure must not hand it back a second time.
    @Test func aFailureAfterTheCaptionPostedDoesNotRestoreIt() async throws {
        let backend = FailingSecondUploadBackend()
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let model = ChatSessionModel(store: store, engine: engine, me: nil, markReadDebounce: .zero)
        try await model.start()
        await settleAutoMarkRead()
        model.select(FixtureWorld.minimal.messages[0].conversationID)
        await settleAutoMarkRead()

        model.stage([Self.file("a"), Self.file("b")])
        model.send("caption")
        await settleAutoMarkRead(until: "the send stopped") {
            model.stagedAttachments.map(\.state) == [.failed]
        }
        #expect(model.stagedAttachments.map(\.id) == ["b"])
        #expect(model.failedDraft == nil)
        await model.stop()
    }

    @Test func aFileCannotBeRemovedWhileItUploads() async throws {
        let backend = RecordingBackend()
        let (model, _) = try await Self.model(backend)
        model.stage([Self.file("a"), Self.file("b")])
        model.unstage("b")
        #expect(model.stagedAttachments.map(\.id) == ["a"])

        await backend.holdSubmissions(true)
        model.send("")
        await settleAutoMarkRead(until: "the message is held") { await backend.heldSubmissionCount == 1 }
        model.unstage("a")
        #expect(model.stagedAttachments.map(\.id) == ["a"])
        await backend.releaseHeldSubmission()
        await settleAutoMarkRead(until: "sent") { model.stagedAttachments.isEmpty }
        await model.stop()
    }

    /// The host keeps the bytes it already has rather than fetching back what
    /// it just sent.
    @Test func theHostIsToldOfEachUploadWithItsFile() async throws {
        let backend = RecordingBackend()
        let (model, _) = try await Self.model(backend)
        var told: [String] = []
        model.didUpload = { attachment, file in told.append("\(file.id)>\(attachment.name)") }
        model.stage([Self.file("a")])
        model.send("")
        await settleAutoMarkRead(until: "sent") { model.stagedAttachments.isEmpty }
        #expect(told == ["a>a.png"])
        await model.stop()
    }

    @Test func stopCancelsASendInFlight() async throws {
        let backend = RecordingBackend()
        let (model, _) = try await Self.model(backend)
        model.stage([Self.file("a"), Self.file("b")])
        await backend.holdSubmissions(true)
        model.send("")
        await settleAutoMarkRead(until: "the first message is held") { await backend.heldSubmissionCount == 1
        }
        #expect(model.composerFiles.sends.count == 1)
        await model.stop()
        #expect(model.composerFiles.sends.isEmpty)
        await backend.releaseHeldSubmission()
        await settleAutoMarkRead()
        // The second file was never uploaded: the cancelled send stopped.
        #expect(await backend.uploads.map(\.id) == ["a"])
    }

    @Test func aBackendThatCannotUploadStagesNothing() async throws {
        var capabilities = Capabilities.fixture
        capabilities.canSendAttachments = false
        let backend = RecordingBackend(capabilities: capabilities)
        let (model, _) = try await Self.model(backend)
        model.stage([Self.file("a")])
        #expect(model.stagedAttachments.isEmpty)
        await model.stop()
    }
}

/// Uploads the first file and refuses every later one, so a failure can
/// land after the caption has already been posted.
private actor FailingSecondUploadBackend: ChatBackend {
    nonisolated let capabilities = Capabilities.fixture
    nonisolated var events: AsyncStream<ChatEvent> {
        inner.events
    }

    private nonisolated let inner = FakeBackend(world: .minimal)
    private var uploads = 0

    func connect() async throws {
        try await inner.connect()
    }

    func disconnect() async {
        await inner.disconnect()
    }

    func send(_ command: ChatCommand) async throws {
        try await inner.send(command)
    }

    func loadConversations() async throws -> [Conversation] {
        try await inner.loadConversations()
    }

    func loadMessages(in conversation: Conversation.ID, before: Message.ID?) async throws -> [Message] {
        try await inner.loadMessages(in: conversation, before: before)
    }

    func setNotificationSetting(_ level: NotificationLevel, for conversation: Conversation.ID) async throws {
        try await inner.setNotificationSetting(level, for: conversation)
    }

    func uploadAttachment(
        _ attachment: OutgoingAttachment,
        to conversation: Conversation.ID,
        progress: @escaping @Sendable (AttachmentProgress) -> Void
    ) async throws -> ChatKit.Attachment {
        uploads += 1
        guard uploads == 1 else { throw ChatError.transport("the second upload failed") }
        return try await inner.uploadAttachment(attachment, to: conversation, progress: progress)
    }
}
