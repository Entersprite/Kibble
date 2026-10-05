import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import SyncEngine

/// `SyncEngine.customEmojiImage(_:)`: forwarded, never recorded, like
/// `attachmentData(_:size:)`.
@Suite(.timeLimit(.minutes(1)))
struct CustomEmojiForwardingTests {
    private static let parrot = CustomEmojiRef(id: "e-1", shortcode: ":parrot:", imageToken: "t")

    /// The smallest backend that implements the image: the fixture refuses it.
    private struct Imaging: ChatBackend {
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
            Data("image-of-\(emoji.id)".utf8)
        }
    }

    @Test func theBackendsBytesComeThroughUnchanged() async throws {
        let engine = try SyncEngine(backend: Imaging(), store: ChatStore.inMemory())
        #expect(try await engine.customEmojiImage(Self.parrot) == Data("image-of-e-1".utf8))
    }

    @Test func aRefusalIsThrownNotRecorded() async throws {
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(
            backend: FakeBackend(world: .acme, capabilities: Capabilities()),
            store: store
        )
        await #expect(throws: ChatError.unsupported(capability: "canFetchCustomEmoji")) {
            _ = try await engine.customEmojiImage(Self.parrot)
        }
        #expect(try store.lastError() == nil)
    }
}
