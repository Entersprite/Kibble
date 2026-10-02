import Foundation
import Testing
@testable import ChatKit

/// `ChatBackend.attachmentData(_:size:)`'s default: a backend that has not
/// thought about attachments refuses, the same direction every capability
/// defaults in.
@Suite("Attachment data")
struct AttachmentDataTests {
    /// Implements every requirement but the attachment one.
    private struct BackendWithoutAttachments: ChatBackend {
        var capabilities: Capabilities {
            Capabilities()
        }

        var events: AsyncStream<ChatEvent> {
            AsyncStream { $0.finish() }
        }

        func connect() async throws {}
        func disconnect() async {}
        func send(_: ChatCommand) async throws {}
        func loadConversations() async throws -> [Conversation] {
            []
        }

        func loadMessages(in _: Conversation.ID, before _: Message.ID?) async throws -> [Message] {
            []
        }

        func setNotificationSetting(_: NotificationLevel, for _: Conversation.ID) async throws {}
    }

    private struct BackendWithAttachments: ChatBackend {
        var capabilities: Capabilities {
            Capabilities(canFetchAttachments: true)
        }

        var events: AsyncStream<ChatEvent> {
            AsyncStream { $0.finish() }
        }

        func connect() async throws {}
        func disconnect() async {}
        func send(_: ChatCommand) async throws {}
        func loadConversations() async throws -> [Conversation] {
            []
        }

        func loadMessages(in _: Conversation.ID, before _: Message.ID?) async throws -> [Message] {
            []
        }

        func setNotificationSetting(_: NotificationLevel, for _: Conversation.ID) async throws {}

        func attachmentData(_ attachment: ChatKit.Attachment, size: AttachmentSize) async throws -> Data {
            Data("\(attachment.id)/\(size.rawValue)".utf8)
        }

        func downloadAttachment(
            _: ChatKit.Attachment, to destination: URL,
            progress: @escaping @Sendable (AttachmentProgress) -> Void
        ) async throws {
            progress(AttachmentProgress(bytesReceived: 1, totalBytes: 1))
            try Data("x".utf8).write(to: destination)
        }
    }

    /// The trap this pins: a method declared only in a protocol extension is
    /// dispatched statically, so through `any ChatBackend` - which is how
    /// `SyncEngine` holds its backend - the refusing default would run even on
    /// a backend that implements the method.
    @Test("an implementation is reached through the existential")
    func existentialReachesTheImplementation() async throws {
        let backend: any ChatBackend = BackendWithAttachments()
        let data = try await backend.attachmentData(Fixture.imageAttachment, size: .original)
        #expect(data == Data("upload-token-1/original".utf8))
    }

    @Test("a backend without the capability refuses, naming it")
    func defaultRefuses() async {
        await #expect(throws: ChatError.unsupported(capability: "canFetchAttachments")) {
            let backend: any ChatBackend = BackendWithoutAttachments()
            _ = try await backend.attachmentData(Fixture.imageAttachment, size: .preview)
        }
    }

    @Test("a backend that has not thought about downloads refuses, named by its capability")
    func downloadRefusesByDefault() async throws {
        let backend: any ChatBackend = BackendWithoutAttachments()
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        await #expect(throws: ChatError.unsupported(capability: "canDownloadFiles")) {
            try await backend.downloadAttachment(
                ChatKit.Attachment(id: "a", name: "a.pdf", contentType: "application/pdf"),
                to: destination,
                progress: { _ in }
            )
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
    }

    /// Through `any ChatBackend`, which is how `SyncEngine` holds a backend:
    /// an extension-only method would dispatch statically to the refusing default.
    @Test("an implementing backend is reached through the existential")
    func downloadDispatchesDynamically() async throws {
        let backend: any ChatBackend = BackendWithAttachments()
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        try await backend.downloadAttachment(
            ChatKit.Attachment(id: "a", name: "a.pdf", contentType: "application/pdf"),
            to: destination,
            progress: { _ in }
        )
        #expect(try Data(contentsOf: destination) == Data("x".utf8))
    }
}
