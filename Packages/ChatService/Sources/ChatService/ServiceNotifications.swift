import ChatAPI
import ChatKit
import Foundation

/// One trusted process/device notification host, independent of chat consumers.
/// Implementations decode frames; no platform object crosses the API contract.
public protocol ServiceNotificationHost: Sendable {
    var deviceID: ServiceDeviceID { get }
    func state(account: ConnectedAccountID) async -> NotificationDeviceState
    func deliver(_ frame: Data) async throws
}

public struct ServiceNotificationItem: Sendable {
    public let sequence: Int64
    public let conversation: Conversation.ID
    public let message: Message.ID?
    public let readPosition: Date?
    public init(sequence: Int64, conversation: Conversation.ID, message: Message.ID?, readPosition: Date?) {
        self.sequence = sequence; self.conversation = conversation
        self.message = message; self.readPosition = readPosition
    }
}

public struct ServiceNotificationPage: Sendable {
    public let items: [ServiceNotificationItem]
    public let checkpoint: Int64
    public let reset: Bool
    public init(items: [ServiceNotificationItem], checkpoint: Int64, reset: Bool) {
        self.items = items; self.checkpoint = checkpoint; self.reset = reset
    }
}

public struct ServiceNotificationFacts: Sendable {
    public let message: Message
    public let conversation: Conversation
    public let members: [Member]
    public let me: Member.ID?
    public let thread: MessageThread?
    public init(
        message: Message,
        conversation: Conversation,
        members: [Member],
        me: Member.ID?,
        thread: MessageThread?
    ) {
        self.message = message; self.conversation = conversation; self.members = members
        self.me = me; self.thread = thread
    }
}

public protocol ServiceNotificationStorage: Sendable {
    /// A new device starts at the current outbox position, never old history.
    func initializeNotifications(for device: ServiceDeviceID) throws
    func notifications(for device: ServiceDeviceID) throws -> ServiceNotificationPage
    func acknowledgeNotifications(for device: ServiceDeviceID, through sequence: Int64) throws
    func notificationFacts(_ message: Message.ID) throws -> ServiceNotificationFacts?
}
