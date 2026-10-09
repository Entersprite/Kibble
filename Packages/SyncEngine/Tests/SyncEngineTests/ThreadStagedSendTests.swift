import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import SyncEngine

/// Files staged in the thread panel (session 60): kept apart from the
/// conversation's, uploaded the way the conversation's are, and posted into
/// the thread as replies.
///
/// **In the background** (`setActive(false)`), as `ThreadPanelTests` is, so
/// the panel's auto-mark-read sends nothing these tests count.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct ThreadStagedSendTests {
    private let thread = ThreadFixture.thread

    private static func file(_ id: String) -> OutgoingAttachment {
        OutgoingAttachment(
            id: id, file: URL(fileURLWithPath: "/nonexistent/\(id).png"), name: "\(id).png",
            contentType: "image/png", byteSize: 100, width: 40, height: 30
        )
    }

    /// The panel open on the fixture thread, and you known, so a reply
    /// writes its optimistic row.
    private func opened() async throws -> AutoMarkReadHarness {
        let harness = try await makeThreadHarness()
        harness.model.setActive(false)
        try openStoredThread(ThreadFixture.messages(replies: 1), in: harness)
        await settleAutoMarkRead(until: "the thread reaches the panel and you are known") {
            harness.model.threads.messages.count == 2 && harness.model.me != nil
        }
        return harness
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

    @Test func filesStagedInAThreadStayOutOfTheConversationsComposer() async throws {
        let harness = try await opened()
        let model = harness.model
        model.stage([Self.file("a")], in: .openThread)
        model.stage([Self.file("b")], in: .conversation)
        #expect(model.threadStagedAttachments.map(\.id) == ["a"])
        #expect(model.stagedAttachments.map(\.id) == ["b"])
        // Removing from the other place removes nothing.
        model.unstage("a", in: .conversation)
        #expect(model.threadStagedAttachments.map(\.id) == ["a"])
        model.unstage("a", in: .openThread)
        #expect(model.threadStagedAttachments.isEmpty)
        #expect(model.stagedAttachments.map(\.id) == ["b"])
        await model.stop()
    }

    @Test func aReplyWithAFileIsPostedIntoTheThreadAndShownOnlyInThePanel() async throws {
        let harness = try await opened()
        let model = harness.model
        model.stage([Self.file("a")], in: .openThread)
        model.sendReply(ComposedMessage(text: "see attached"))
        await settleAutoMarkRead(until: "the staged file has gone") { model.threadStagedAttachments.isEmpty }

        let sent = await Self.sends(harness.backend)
        guard case let .sendMessage(conversation, threadID, text, _, attachments, _)? = sent.first else {
            Issue.record("expected one sendMessage")
            return
        }
        #expect(sent.count == 1)
        #expect(conversation == ThreadFixture.conversation)
        #expect(threadID == thread)
        #expect(text == "see attached")
        #expect(attachments.map(\.name) == ["a.png"])
        await settleAutoMarkRead(until: "the reply reaches the panel") {
            model.threads.messages.contains { $0.attachments.map(\.name) == ["a.png"] }
        }
        let reply = try #require(model.threads.messages.first { $0.attachments.map(\.name) == ["a.png"] })
        #expect(reply.isReply)
        #expect(reply.threadID == thread)
        #expect(reply.text == "see attached")
        // The positive control: a top-level message sent after the reply
        // reaches the transcript, so the transcript has seen the reply's write.
        model.send(ComposedMessage(text: "top level"))
        await settleAutoMarkRead(until: "the top-level message reaches the transcript") {
            model.messages.contains { $0.text == "top level" }
        }
        #expect(!model.messages.contains { $0.attachments.map(\.name) == ["a.png"] })
        await model.stop()
    }

    /// Only a staged file makes an empty reply mean something, as for `send`.
    @Test func aReplyOfFilesAloneIsSent() async throws {
        let harness = try await opened()
        let model = harness.model
        model.stage([Self.file("a"), Self.file("b")], in: .openThread)
        model.sendReply(ComposedMessage(text: ""))
        await settleAutoMarkRead(until: "both sent") { model.threadStagedAttachments.isEmpty }
        let shapes = await Self.sends(harness.backend).compactMap { command -> String? in
            guard case let .sendMessage(_, threadID, text, _, attachments, _) = command else { return nil }
            return "\(threadID?.rawValue ?? "-")|\(text)|\(attachments.map(\.name).joined())"
        }
        #expect(shapes == ["thread:test||a.png", "thread:test||b.png"])
        await model.stop()
    }

    /// The files stay for Send to try again. The text is not handed back:
    /// the restore slot is the conversation composer's, and a reply restored
    /// there would post at the top level (`sendReply`'s rule).
    @Test func aRefusedUploadKeepsTheFilesAndRestoresNothingInTheConversation() async throws {
        let harness = try await opened()
        let model = harness.model
        model.stage([Self.file("a"), Self.file("b")], in: .openThread)
        await harness.backend.failUploads(true)
        model.sendReply(ComposedMessage(text: "caption"))
        await settleAutoMarkRead(until: "the send stopped") {
            !model.threadStagedAttachments.isEmpty && model.threadStagedAttachments
                .allSatisfy { !$0.isUploading }
        }
        #expect(model.threadStagedAttachments.map(\.state) == [.failed, .ready])
        #expect(await Self.sends(harness.backend).isEmpty)
        #expect(model.failedDraft == nil)
        await settleAutoMarkRead(until: "the refusal is recorded") { model.lastError != nil }
        await model.stop()
    }

    /// A send belongs to the thread its files were staged in, not to whatever
    /// is open when the upload answers: closing the panel mid-upload still
    /// posts into that thread, as a reply (session 60 review, Minor 1).
    @Test func aReplyUploadingWhenThePanelClosesStillPostsIntoItsThread() async throws {
        let harness = try await opened()
        let model = harness.model
        model.stage([Self.file("a")], in: .openThread)
        await harness.backend.holdUploads(true)
        model.sendReply(ComposedMessage(text: "caption"))
        await settleAutoMarkRead(until: "the upload is held") { await harness.backend.heldUploadCount == 1 }
        model.closeThread()
        await harness.backend.releaseHeldUpload()
        await settleAutoMarkRead(until: "the reply is sent") { await Self.sends(harness.backend).count == 1 }
        guard case let .sendMessage(_, threadID, text, _, attachments, _)? = await Self.sends(harness.backend)
            .first
        else {
            Issue.record("expected one sendMessage")
            return
        }
        #expect(threadID == thread)
        #expect(text == "caption")
        #expect(attachments.map(\.name) == ["a.png"])
        model.openThread(thread)
        await settleAutoMarkRead(until: "the reply is in the reopened panel") {
            model.threads.messages.contains { $0.attachments.map(\.name) == ["a.png"] && $0.isReply }
        }
        #expect(model.stagedAttachments.isEmpty)
        await model.stop()
    }

    /// Staged files wait in their thread while it is closed, shown nowhere
    /// else, and are there again when it reopens.
    @Test func stagedFilesWaitInTheirThreadWhileItIsClosed() async throws {
        let harness = try await opened()
        let model = harness.model
        model.stage([Self.file("a")], in: .openThread)
        model.closeThread()
        #expect(model.threadStagedAttachments.isEmpty)
        #expect(model.stagedAttachments.isEmpty)
        model.openThread(thread)
        #expect(model.threadStagedAttachments.map(\.id) == ["a"])
        await model.stop()
    }

    /// A reply's upload is one of the sends `stop()` cancels, and its staged
    /// files go with the rest.
    @Test func stopCancelsAReplysUpload() async throws {
        let harness = try await opened()
        let model = harness.model
        model.stage([Self.file("a")], in: .openThread)
        await harness.backend.holdUploads(true)
        model.sendReply(ComposedMessage(text: "caption"))
        await settleAutoMarkRead(until: "the upload is held") { await harness.backend.heldUploadCount == 1 }
        #expect(model.composerFiles.sends.count == 1)
        await model.stop()
        #expect(model.composerFiles.sends.isEmpty)
        #expect(model.composerFiles.staged.isEmpty)
        await harness.backend.releaseHeldUpload()
        await settleAutoMarkRead()
        #expect(await Self.sends(harness.backend).isEmpty)
    }
}
