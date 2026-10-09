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

    /// `me` is the fixture's own user, so `post` writes its optimistic row:
    /// with `nil` there is no row, and a test of its retraction proves
    /// nothing (session 50's review, Important 3).
    private static func model(
        _ backend: RecordingBackend
    ) async throws -> (ChatSessionModel, Conversation.ID) {
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let model = ChatSessionModel(
            store: store, engine: engine, me: FixtureWorld.minimal.me, markReadDebounce: .zero
        )
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
        model.stage([Self.file("a")], in: .conversation)
        #expect(model.stagedAttachments.map(\.id) == ["a"])

        model.send(ComposedMessage(text: "caption"))
        await settleAutoMarkRead(until: "the staged file has gone") { model.stagedAttachments.isEmpty }

        #expect(await backend.uploads.map(\.id) == ["a"])
        let sent = await Self.sends(backend)
        guard case let .sendMessage(sentTo, _, text, _, attachments, _)? = sent.first else {
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
        model.stage([Self.file("a"), Self.file("b")], in: .conversation)
        model.send(ComposedMessage(text: "hello"))
        await settleAutoMarkRead(until: "both sent") { model.stagedAttachments.isEmpty }

        let sent = await Self.sends(backend)
        let shapes = sent.compactMap { command -> String? in
            guard case let .sendMessage(_, _, text, _, attachments, _) = command else { return nil }
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
        model.stage([Self.file("a"), Self.file("a")], in: .conversation)
        model.stage([Self.file("huge", byteSize: OutgoingAttachment.maximumByteSize + 1)], in: .conversation)
        #expect(model.stagedAttachments.map(\.id) == ["a"])
        await settleAutoMarkRead(until: "the oversize banner") { model.lastError != nil }
        await model.stop()
    }

    @Test func stagedFilesBelongToTheirConversation() async throws {
        let backend = RecordingBackend()
        let (model, first) = try await Self.model(backend)
        model.stage([Self.file("a")], in: .conversation)
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
        model.stage([Self.file("a"), Self.file("b")], in: .conversation)
        await backend.failUploads(true)
        model.send(ComposedMessage(text: "caption"))
        await settleAutoMarkRead(until: "the send stopped") {
            model.stagedAttachments.allSatisfy { !$0.isUploading }
        }

        #expect(model.stagedAttachments.map(\.state) == [.failed, .ready])
        #expect(await Self.sends(backend).isEmpty)
        #expect(model.failedDraft?.text == "caption")
        #expect(model.lastError != nil)

        // Send tries the failed one again.
        await backend.failUploads(false)
        model.send(ComposedMessage(text: ""))
        await settleAutoMarkRead(until: "both sent") { model.stagedAttachments.isEmpty }
        #expect(await Self.sends(backend).count == 2)
        await model.stop()
    }

    /// The upload worked and the message was refused: the file is kept, the
    /// text comes back, and the optimistic row - there while the post was in
    /// flight - is retracted.
    @Test func aRefusedMessageKeepsTheFile() async throws {
        let backend = RecordingBackend()
        let (model, conversation) = try await Self.model(backend)
        model.stage([Self.file("a")], in: .conversation)
        await backend.failSubmissions(true)
        await backend.holdSubmissions(true)
        model.send(ComposedMessage(text: "caption"))
        await settleAutoMarkRead(until: "the post is held") { await backend.heldSubmissionCount == 1 }
        // Positive control: the row this test says is retracted exists.
        let during = try model.store.messages(in: conversation)
        #expect(during.contains { $0.id.rawValue.hasPrefix("local/") && $0.attachments.count == 1 })

        await backend.releaseHeldSubmission()
        await settleAutoMarkRead(until: "the send stopped") {
            model.stagedAttachments.allSatisfy { !$0.isUploading }
        }
        #expect(model.stagedAttachments.map(\.state) == [.failed])
        #expect(model.failedDraft?.text == "caption")
        let rows = try model.store.messages(in: conversation)
        #expect(!rows.contains { $0.id.rawValue.hasPrefix("local/") })
        await model.stop()
    }

    /// The optimistic row and the echo are one message, attachment and all.
    @Test func theEchoReplacesTheOptimisticRowWithItsAttachment() async throws {
        let backend = RecordingBackend()
        let (model, conversation) = try await Self.model(backend)
        let before = try model.store.messages(in: conversation).count
        model.stage([Self.file("a")], in: .conversation)
        model.send(ComposedMessage(text: "caption"))
        await settleAutoMarkRead(until: "sent") { model.stagedAttachments.isEmpty }
        await settleAutoMarkRead(until: "the echo replaced the row") {
            (try? model.store.messages(in: conversation))?
                .contains { $0.id.rawValue.hasPrefix("local/") } == false
        }
        let rows = try model.store.messages(in: conversation)
        #expect(rows.count == before + 1)
        #expect(rows.last?.attachments.map(\.name) == ["a.png"])
        #expect(rows.last?.text == "caption")
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

        model.stage([Self.file("a"), Self.file("b")], in: .conversation)
        model.send(ComposedMessage(text: "caption"))
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
        model.stage([Self.file("a"), Self.file("b")], in: .conversation)
        model.unstage("b", in: .conversation)
        #expect(model.stagedAttachments.map(\.id) == ["a"])

        await backend.holdSubmissions(true)
        model.send(ComposedMessage(text: ""))
        await settleAutoMarkRead(until: "the message is held") { await backend.heldSubmissionCount == 1 }
        model.unstage("a", in: .conversation)
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
        model.stage([Self.file("a")], in: .conversation)
        model.send(ComposedMessage(text: ""))
        await settleAutoMarkRead(until: "sent") { model.stagedAttachments.isEmpty }
        #expect(told == ["a>a.png"])
        await model.stop()
    }

    /// The post is accepted after `stop()`, so only the cancellation can
    /// keep the second file from uploading (session 50's review, Important
    /// 2: with the post failing, the send stopped either way).
    @Test func stopCancelsASendWhosePostIsInFlight() async throws {
        let backend = RecordingBackend()
        let (model, _) = try await Self.model(backend)
        model.stage([Self.file("a"), Self.file("b")], in: .conversation)
        await backend.holdSubmissions(true)
        await backend.acceptWithoutForwarding(true)
        model.send(ComposedMessage(text: "caption"))
        await settleAutoMarkRead(until: "the first message is held") { await backend.heldSubmissionCount == 1
        }
        #expect(model.composerFiles.sends.count == 1)
        await model.stop()
        #expect(model.composerFiles.sends.isEmpty)
        #expect(model.composerFiles.staged.isEmpty)
        await backend.releaseHeldSubmission()
        await settleAutoMarkRead()
        #expect(await backend.uploads.map(\.id) == ["a"])
    }

    /// An upload that fails after `stop()` must not hand its caption back
    /// into a model that has been stopped.
    @Test func stopCancelsASendWhoseUploadIsInFlight() async throws {
        let backend = RecordingBackend()
        let (model, _) = try await Self.model(backend)
        model.stage([Self.file("a")], in: .conversation)
        await backend.holdUploads(true)
        await backend.failUploads(true)
        model.send(ComposedMessage(text: "caption"))
        await settleAutoMarkRead(until: "the upload is held") { await backend.heldUploadCount == 1 }
        await model.stop()
        await backend.releaseHeldUpload()
        await settleAutoMarkRead()
        #expect(model.failed == nil)
        #expect(model.lastError == nil)
    }

    /// An upload that succeeds after `stop()` must not be posted, nor told
    /// to the host, for an account that has been stopped.
    @Test func anUploadAnsweringAfterStopIsNotPosted() async throws {
        let backend = RecordingBackend()
        let (model, conversation) = try await Self.model(backend)
        var told = 0
        model.didUpload = { _, _ in told += 1 }
        model.stage([Self.file("a")], in: .conversation)
        await backend.holdUploads(true)
        await backend.acceptWithoutForwarding(true)
        model.send(ComposedMessage(text: "caption"))
        await settleAutoMarkRead(until: "the upload is held") { await backend.heldUploadCount == 1 }
        await model.stop()
        await backend.releaseHeldUpload()
        await settleAutoMarkRead()
        #expect(told == 0)
        #expect(await Self.sends(backend).isEmpty)
        #expect(try !model.store.messages(in: conversation).contains { $0.id.rawValue.hasPrefix("local/") })
    }

    @Test func aBackendThatCannotUploadStagesNothing() async throws {
        var capabilities = Capabilities.fixture
        capabilities.canSendAttachments = false
        let backend = RecordingBackend(capabilities: capabilities)
        let (model, _) = try await Self.model(backend)
        model.stage([Self.file("a")], in: .conversation)
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
