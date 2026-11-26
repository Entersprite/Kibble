import ChatKit
import Foundation

public struct GetMessagePins: ServiceRequestPayload {
    public typealias Response = PinnedMessages
    public static let operation = "getMessagePins"
    public static let requiresAccount = true
    public let conversationID: Conversation.ID

    public init(conversationID: Conversation.ID) {
        self.conversationID = conversationID
    }
}

public struct SetMessagePinned: ServiceRequestPayload {
    public typealias Response = PinnedMessages
    public static let operation = "setMessagePinned"
    public static let requiresAccount = true
    public let address: MessageAddress
    public let pinned: Bool
    public let operationID: ServiceOperationID

    public init(address: MessageAddress, pinned: Bool, operationID: ServiceOperationID) {
        self.address = address
        self.pinned = pinned
        self.operationID = operationID
    }
}
