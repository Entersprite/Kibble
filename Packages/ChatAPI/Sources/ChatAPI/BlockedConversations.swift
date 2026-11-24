import ChatKit

public struct GetBlockedConversations: ServiceRequestPayload {
    public typealias Response = [BlockedConversation]
    public static let operation = "getBlockedConversations"
    public static let requiresAccount = true

    public init() {}
}

public struct UnblockConversation: ServiceRequestPayload {
    public typealias Response = [BlockedConversation]
    public static let operation = "unblockConversation"
    public static let requiresAccount = true
    public let conversation: Conversation.ID
    public let operationID: ServiceOperationID

    public init(conversation: Conversation.ID, operationID: ServiceOperationID) {
        self.conversation = conversation
        self.operationID = operationID
    }
}
