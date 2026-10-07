import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import SyncEngine

/// `SyncEngine.remoteImage(_:)`: forwarded, never recorded, like
/// `attachmentData(_:size:)`.
@Suite(.timeLimit(.minutes(1)))
struct RemoteImageForwardingTests {
    private static let url = URL(string: "https://acme.example/a.png")!

    /// The smallest backend that implements the image: the fixture refuses it.
    private struct Imaging: ChatBackend {
        var capabilities: Capabilities {
            Capabilities(canFetchRemoteImages: true)
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
        func remoteImage(_ url: URL) async throws -> Data {
            Data("image-of-\(url.lastPathComponent)".utf8)
        }
    }

    @Test func theBackendsBytesComeThroughUnchanged() async throws {
        let engine = try SyncEngine(backend: Imaging(), store: ChatStore.inMemory())
        #expect(try await engine.remoteImage(Self.url) == Data("image-of-a.png".utf8))
    }

    @Test func aRefusalIsThrownNotRecorded() async throws {
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(
            backend: FakeBackend(world: .acme, capabilities: Capabilities()),
            store: store
        )
        await #expect(throws: ChatError.unsupported(capability: "canFetchRemoteImages")) {
            _ = try await engine.remoteImage(Self.url)
        }
        #expect(try store.lastError() == nil)
    }
}
