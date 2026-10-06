import Foundation
import Testing
@testable import ChatKit

/// `ChatBackend.searchPeople(_:)` and `membership(of:in:)`: refusing by
/// default, and reached through `any ChatBackend` when implemented (CLAUDE.md,
/// session 38). Mention non-members spec §3.1.
@Suite("People requests")
struct PeopleRequestTests {
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
            Capabilities(canMentionNonMembers: true)
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
        func searchPeople(_ query: String) async throws -> [Member] {
            [Member(id: Member.ID(query), kind: .human)]
        }

        func membership(of _: Member.ID, in _: Conversation.ID) async throws -> ConversationMembership {
            .notMember
        }
    }

    @Test func theDefaultsRefuseNamingTheCapability() async {
        let backend: any ChatBackend = Plain()
        await #expect(throws: ChatError.unsupported(capability: "canMentionNonMembers")) {
            _ = try await backend.searchPeople("a")
        }
        await #expect(throws: ChatError.unsupported(capability: "canMentionNonMembers")) {
            _ = try await backend.membership(of: Member.ID("u"), in: Conversation.ID("space/s"))
        }
    }

    @Test func anImplementationIsReachedThroughTheExistential() async throws {
        let backend: any ChatBackend = Implementing()
        #expect(try await backend.searchPeople("jo").map(\.id) == [Member.ID("jo")])
        #expect(try await backend
            .membership(of: Member.ID("u"), in: Conversation.ID("space/s")) == .notMember)
    }
}
