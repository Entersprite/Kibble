import Foundation
import Testing
@testable import ChatKit

/// `ChatBackend.uploadAttachment(_:to:progress:)`: refusing by default, and
/// reached through `any ChatBackend` when implemented (session 38 §4.1).
@Suite("Upload attachment")
struct UploadAttachmentTests {
    private static let file = OutgoingAttachment(
        id: "o-1", file: URL(fileURLWithPath: "/tmp/a.png"), name: "a.png", contentType: "image/png",
        byteSize: 3
    )

    private struct Plain: ChatBackend {
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

    private struct Implementing: ChatBackend {
        var capabilities: Capabilities {
            Capabilities(canSendAttachments: true)
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
        func uploadAttachment(
            _ attachment: OutgoingAttachment,
            to _: Conversation.ID,
            progress _: @escaping @Sendable (AttachmentProgress) -> Void
        ) async throws -> ChatKit.Attachment {
            ChatKit.Attachment(
                id: "token-for-\(attachment.id)",
                name: attachment.name,
                contentType: attachment.contentType
            )
        }
    }

    @Test func theDefaultRefusesNamingTheCapability() async {
        await #expect(throws: ChatError.unsupported(capability: "canSendAttachments")) {
            let backend: any ChatBackend = Plain()
            _ = try await backend.uploadAttachment(Self.file, to: .init("dm:1")) { _ in }
        }
    }

    @Test func anImplementationIsReachedThroughTheExistential() async throws {
        let backend: any ChatBackend = Implementing()
        let uploaded = try await backend.uploadAttachment(Self.file, to: .init("dm:1")) { _ in }
        #expect(uploaded.id == "token-for-o-1")
    }

    /// The other direction of the compatibility rule: a frame written before
    /// attachments existed decodes to none, and a send with none writes no key.
    @Test func aFrameWithoutAttachmentsDecodesToNone() throws {
        let json = #"{"conversationID":"dm:1","text":"hi","type":"sendMessage"}"#
        let command = try Wire.decode(ChatCommand.self, from: json)
        #expect(command == .sendMessage(
            conversationID: .init("dm:1"),
            threadID: nil,
            text: "hi",
            localID: nil
        ))
        #expect(try Wire.json(command) == json)
    }
}
