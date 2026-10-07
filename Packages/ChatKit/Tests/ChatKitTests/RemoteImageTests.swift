import Foundation
import Testing
@testable import ChatKit

/// `ChatBackend.remoteImage(_:)` (links spec §3.3): refusing by default, and
/// reached through `any ChatBackend` when implemented.
@Suite("Remote image")
struct RemoteImageTests {
    private static let url = URL(string: "https://acme.example/a.png")!

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
            Data(url.absoluteString.utf8)
        }
    }

    /// Through `any ChatBackend`, the way `SyncEngine` holds it (CLAUDE.md:
    /// a protocol default must also be a requirement).
    @Test func anImplementingBackendAnswersThroughTheExistential() async throws {
        let backend: any ChatBackend = Imaging()
        #expect(try await backend.remoteImage(Self.url) == Data("https://acme.example/a.png".utf8))
    }

    @Test func theDefaultRefuses() async {
        let backend: any ChatBackend = Plain()
        await #expect(throws: ChatError.unsupported(capability: "canFetchRemoteImages")) {
            _ = try await backend.remoteImage(Self.url)
        }
    }

    @Test func aMissingKeyIsFalse() throws {
        #expect(try !Wire.decode(Capabilities.self, from: "{}").canFetchRemoteImages)
    }
}
