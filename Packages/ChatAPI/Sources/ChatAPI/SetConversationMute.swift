import ChatKit

public struct SetConversationMute: ServiceRequestPayload {
    public typealias Response = ServiceUnit
    public static let operation = "setConversationMute"
    public static let requiresAccount = true
    public let pause: Pause
    public let conversationID: Conversation.ID

    public init(pause: Pause, conversationID: Conversation.ID) {
        self.pause = pause
        self.conversationID = conversationID
    }
}
