import ChatKit
import FixtureBackend
import Foundation

actor DeliveryStatusBackend: MessageDeliveryTrackingBackend {
    nonisolated let inner = RecordingBackend()
    nonisolated var capabilities: Capabilities {
        inner.capabilities
    }

    nonisolated let events: AsyncStream<ChatEvent>
    private let continuation: AsyncStream<ChatEvent>.Continuation
    init() {
        (events, continuation) = AsyncStream.makeStream()
    }

    private(set) var sends: [ChatCommand] = []
    private(set) var statusChecks: [String] = []
    private var status = MessageDeliveryStatus.unconfirmed
    private var refused = false
    private var uncertain = true
    private var holdingStatus = false
    private var holdingSend = false
    private var heldSend: [CheckedContinuation<Void, Never>] = []
    private var heldStatus: [CheckedContinuation<Void, Never>] = []
    var heldStatusCount: Int {
        heldStatus.count
    }

    var heldSendCount: Int {
        heldSend.count
    }

    func holdSend() {
        holdingSend = true
    }

    func releaseSend() {
        holdingSend = false
        let held = heldSend; heldSend = []
        held.forEach { $0.resume() }
    }

    func refuse() {
        refused = true
    }

    func acceptWithoutEcho() {
        uncertain = false
    }

    func setStatus(_ status: MessageDeliveryStatus) {
        self.status = status
    }

    func holdStatus() {
        holdingStatus = true
    }

    func releaseStatus() {
        holdingStatus = false
        let held = heldStatus; heldStatus = []
        held.forEach { $0.resume() }
    }

    func connect() async throws {
        try await inner.connect()
        try await continuation.yield(.conversationsChanged(inner.loadConversations()))
        continuation.yield(.selfIdentified(Member(id: FixtureWorld.minimal.me, kind: .human)))
        continuation.yield(.connectionStateChanged(.connected))
    }

    func disconnect() async {
        await inner.disconnect()
    }

    func send(_ command: ChatCommand) async throws {
        if case let .sendMessage(_, _, _, localID, _, _, _) = command {
            sends.append(command)
            if holdingSend {
                await withCheckedContinuation { heldSend.append($0) }
            }
            if refused {
                throw ChatError.unsupported(capability: "send refused")
            }
            if uncertain {
                throw UncertainOperation(operationID: localID ?? "unknown")
            }
            return
        }
        try await inner.send(command)
    }

    func deliveryStatus(for localID: String) async -> MessageDeliveryStatus {
        statusChecks.append(localID)
        if holdingStatus {
            await withCheckedContinuation { heldStatus.append($0) }
        }
        return status
    }

    func echo() async {
        guard case let .sendMessage(conversation, thread, text, localID, attachments, mentions, _)? = sends
            .last
        else { return }
        continuation.yield(.messageReceived(Message(
            id: Message.ID("canonical"),
            conversationID: conversation,
            threadID: thread ?? MessageThread.ID("canonical-thread"),
            sender: FixtureWorld.minimal.me,
            text: text,
            createdAt: Date(),
            attachments: attachments,
            localID: localID,
            mentions: mentions,
            isReply: thread != nil
        )))
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

    func uploadAttachment(
        _ attachment: OutgoingAttachment,
        to conversation: Conversation.ID,
        progress: @escaping @Sendable (AttachmentProgress) -> Void
    ) async throws
        -> Attachment {
        try await inner.uploadAttachment(attachment, to: conversation, progress: progress)
    }
}
