import ChatKit
import Foundation

public struct GetScheduledMessages: ServiceRequestPayload {
    public typealias Response = ScheduledMessagesPage
    public static let operation = "getScheduledMessages"
    public static let requiresAccount = true
    public let cursor: String?

    public init(cursor: String?) {
        self.cursor = cursor
    }
}

public struct ScheduleMessage: ServiceRequestPayload {
    public typealias Response = ScheduledMessage
    public static let operation = "scheduleMessage"
    public static let requiresAccount = true
    public let conversation: Conversation.ID
    public let thread: MessageThread.ID?
    public let body: ComposedMessage
    public let deliveryTime: Date
    public let operationID: ServiceOperationID
    public let draft: SyncedDraft?
    public let attachments: [Attachment]?

    public init(
        conversation: Conversation.ID, thread: MessageThread.ID?, body: ComposedMessage,
        deliveryTime: Date, operationID: ServiceOperationID, draft: SyncedDraft? = nil,
        attachments: [Attachment]? = nil
    ) {
        self.conversation = conversation
        self.thread = thread
        self.body = body
        self.deliveryTime = deliveryTime
        self.operationID = operationID
        self.draft = draft
        self.attachments = attachments
    }
}

public struct EditScheduledMessage: ServiceRequestPayload {
    public typealias Response = ScheduledMessage
    public static let operation = "editScheduledMessage"
    public static let requiresAccount = true
    public let address: ScheduledMessageAddress
    public let body: ComposedMessage
    public let operationID: ServiceOperationID

    public init(address: ScheduledMessageAddress, body: ComposedMessage, operationID: ServiceOperationID) {
        self.address = address
        self.body = body
        self.operationID = operationID
    }
}

public struct RescheduleMessage: ServiceRequestPayload {
    public typealias Response = ScheduledMessage
    public static let operation = "rescheduleMessage"
    public static let requiresAccount = true
    public let address: ScheduledMessageAddress
    public let deliveryTime: Date
    public let operationID: ServiceOperationID

    public init(address: ScheduledMessageAddress, deliveryTime: Date, operationID: ServiceOperationID) {
        self.address = address
        self.deliveryTime = deliveryTime
        self.operationID = operationID
    }
}

public struct CancelScheduledMessage: ServiceRequestPayload {
    public typealias Response = ServiceUnit
    public static let operation = "cancelScheduledMessage"
    public static let requiresAccount = true
    public let address: ScheduledMessageAddress
    public let operationID: ServiceOperationID

    public init(address: ScheduledMessageAddress, operationID: ServiceOperationID) {
        self.address = address
        self.operationID = operationID
    }
}

public struct SendScheduledMessageNow: ServiceRequestPayload {
    public typealias Response = ServiceUnit
    public static let operation = "sendScheduledMessageNow"
    public static let requiresAccount = true
    public let address: ScheduledMessageAddress
    public let operationID: ServiceOperationID

    public init(address: ScheduledMessageAddress, operationID: ServiceOperationID) {
        self.address = address
        self.operationID = operationID
    }
}
