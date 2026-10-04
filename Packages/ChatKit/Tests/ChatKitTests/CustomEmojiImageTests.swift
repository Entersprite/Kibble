import Foundation
import Testing
@testable import ChatKit

/// `ChatBackend.customEmojiImage(_:)`: refusing by default, and reached
/// through `any ChatBackend` when implemented (session 38 §4.1).
@Suite("Custom emoji image")
struct CustomEmojiImageTests {
    private static let parrot = CustomEmojiRef(id: "e-1", shortcode: ":parrot:")

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
            Capabilities(canFetchCustomEmoji: true)
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
        func customEmojiImage(_ emoji: CustomEmojiRef) async throws -> Data {
            Data(emoji.id.utf8)
        }
    }

    @Test func theDefaultRefusesNamingTheCapability() async {
        await #expect(throws: ChatError.unsupported(capability: "canFetchCustomEmoji")) {
            let backend: any ChatBackend = Plain()
            _ = try await backend.customEmojiImage(Self.parrot)
        }
    }

    @Test func anImplementationIsReachedThroughTheExistential() async throws {
        let backend: any ChatBackend = Implementing()
        #expect(try await backend.customEmojiImage(Self.parrot) == Data("e-1".utf8))
    }
}
