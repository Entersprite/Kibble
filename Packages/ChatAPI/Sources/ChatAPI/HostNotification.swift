import ChatKit
import Foundation

/// Native host facts, never authority to access another account.
public struct NotificationDeviceState: Sendable {
    public let conversation: Conversation.ID?
    public let thread: MessageThread.ID?
    public let paused: Bool

    public init(conversation: Conversation.ID? = nil, thread: MessageThread.ID? = nil, paused: Bool = false) {
        self.conversation = conversation; self.thread = thread; self.paused = paused
    }
}

/// Serialized service-to-platform notification boundary. Unknown operations
/// preserve their entire payload and must be refused by the receiving host.
public struct HostNotificationFrame: Codable, Hashable, Sendable {
    public let service: ServiceInstanceID
    public let account: ConnectedAccountID
    public let revision: ServiceAccountRevision
    public let deliveryID: String
    public let operation: String
    public let payload: JSONValue

    public init(
        service: ServiceInstanceID, account: ConnectedAccountID, revision: ServiceAccountRevision,
        deliveryID: String, operation: String, payload: JSONValue
    ) {
        self.service = service; self.account = account; self.revision = revision
        self.deliveryID = deliveryID; self.operation = operation; self.payload = payload
    }
}

public struct HostNotificationPost: Codable, Hashable, Sendable {
    public let message: Message
    public let conversation: Conversation
    public let members: [Member]
    public let me: Member.ID
    public let accountLabel: String
    public let isPassive: Bool
    public let playsSound: Bool
    public let showsPreview: Bool
    public let offersMarkRead: Bool

    public init(
        message: Message, conversation: Conversation, members: [Member], me: Member.ID, accountLabel: String,
        isPassive: Bool, playsSound: Bool, showsPreview: Bool, offersMarkRead: Bool
    ) {
        self.message = message; self.conversation = conversation; self.members = members; self.me = me
        self.accountLabel = accountLabel; self.isPassive = isPassive; self.playsSound = playsSound
        self.showsPreview = showsPreview; self.offersMarkRead = offersMarkRead
    }
}

public struct HostNotificationWithdrawal: Codable, Hashable, Sendable {
    public let conversation: Conversation.ID
    public let upTo: Date
    public init(conversation: Conversation.ID, upTo: Date) {
        self.conversation = conversation; self.upTo = upTo
    }
}
