import Foundation
import Testing
@testable import ChatKit

/// `ChatBackend.loadThread(_:in:)`, `setThreadFollowed(_:thread:in:)` and
/// `loadFollowedThreads()`: refusing by default, and reached through
/// `any ChatBackend` when implemented (CLAUDE.md, session 38; threads spec §1).
@Suite("Thread requests")
struct ThreadRequestTests {
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

    private struct Threaded: ChatBackend {
        var capabilities: Capabilities {
            Capabilities(supportsThreads: true)
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

        func loadThread(_ thread: MessageThread.ID, in _: Conversation.ID) async throws -> [Message] {
            var reply = Fixture.reply
            reply.threadID = thread
            return [reply]
        }

        func setThreadFollowed(
            _ followed: Bool, thread _: MessageThread.ID, in _: Conversation.ID
        ) async throws {
            guard followed else { throw ChatError.unknown("unfollow refused") }
        }

        func loadFollowedThreads() async throws -> [Message] {
            [Fixture.message, Fixture.reply]
        }
    }

    @Test func theDefaultsRefuseNamingTheCapability() async {
        let backend: any ChatBackend = Plain()
        await #expect(throws: ChatError.unsupported(capability: "supportsThreads")) {
            _ = try await backend.loadThread(Fixture.threadID, in: Fixture.spaceID)
        }
        await #expect(throws: ChatError.unsupported(capability: "supportsThreads")) {
            try await backend.setThreadFollowed(true, thread: Fixture.threadID, in: Fixture.spaceID)
        }
        await #expect(throws: ChatError.unsupported(capability: "supportsThreads")) {
            _ = try await backend.loadFollowedThreads()
        }
    }

    /// The trap this pins: an extension-only method dispatches statically, so
    /// through `any ChatBackend` the refusing default would answer even for a
    /// backend that implements it.
    @Test func anImplementationIsReachedThroughTheExistential() async throws {
        let backend: any ChatBackend = Threaded()
        let other = MessageThread.ID("space:AAAA1111|topic-78")
        #expect(try await backend.loadThread(other, in: Fixture.spaceID).map(\.threadID) == [other])
        try await backend.setThreadFollowed(true, thread: Fixture.threadID, in: Fixture.spaceID)
        await #expect(throws: ChatError.unknown("unfollow refused")) {
            try await backend.setThreadFollowed(false, thread: Fixture.threadID, in: Fixture.spaceID)
        }
        #expect(try await backend.loadFollowedThreads() == [Fixture.message, Fixture.reply])
    }
}
