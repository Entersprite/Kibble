import ChatKit
import FixtureBackend
import Foundation

actor CallMembershipGate: ChatBackend {
    nonisolated let events: AsyncStream<ChatEvent>
    nonisolated let capabilities: Capabilities
    let inner: FakeBackend
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var held = false

    init(inner: FakeBackend) {
        self.inner = inner; events = inner.events; capabilities = inner.capabilities
    }

    func connect() async throws {
        try await inner.connect()
    }

    func disconnect() async {
        release()
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

    func membership(
        of member: Member.ID,
        in conversation: Conversation.ID
    ) async throws -> ConversationMembership {
        let result = try await inner.membership(of: member, in: conversation)
        held = true
        await withCheckedContinuation { waiter = $0 }
        return result
    }

    func release() {
        waiter?.resume(); waiter = nil
    }
}
