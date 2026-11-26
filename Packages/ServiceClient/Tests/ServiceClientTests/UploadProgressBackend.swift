import ChatKit
import FixtureBackend
import Foundation

actor UploadProgressBackend: ChatBackend {
    nonisolated let capabilities: Capabilities
    nonisolated let events: AsyncStream<ChatEvent>
    let inner: FakeBackend
    private(set) var held = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var callback: (@Sendable (AttachmentProgress) -> Void)?

    init(inner: FakeBackend) {
        self.inner = inner
        capabilities = inner.capabilities
        events = inner.events
    }

    func connect() async throws {
        try await inner.connect()
    }

    func disconnect() async {
        await inner.disconnect()
    }

    func send(_ command: ChatCommand) async throws {
        try await inner.send(command)
    }

    func loadConversations() async throws -> [Conversation] {
        try await inner.loadConversations()
    }

    func loadMessages(in id: Conversation.ID, before: Message.ID?) async throws -> [Message] {
        try await inner.loadMessages(in: id, before: before)
    }

    func setNotificationSetting(_ level: NotificationLevel, for id: Conversation.ID) async throws {
        try await inner.setNotificationSetting(level, for: id)
    }

    func membership(of member: Member.ID, in id: Conversation.ID) async throws -> ConversationMembership {
        try await inner.membership(of: member, in: id)
    }

    func uploadAttachment(
        _ attachment: OutgoingAttachment, to conversation: Conversation.ID,
        progress: @escaping @Sendable (AttachmentProgress) -> Void
    ) async throws -> Attachment {
        callback = progress
        held = true
        await withCheckedContinuation { waiter = $0 }
        try Task.checkCancellation()
        return try await inner.uploadAttachment(attachment, to: conversation, progress: progress)
    }

    func report(_ count: Int) {
        callback?(AttachmentProgress(bytesReceived: count, totalBytes: nil))
    }

    func release() {
        waiter?.resume(); waiter = nil
    }
}
