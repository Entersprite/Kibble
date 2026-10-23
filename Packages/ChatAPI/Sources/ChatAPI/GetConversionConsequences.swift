import ChatKit

public struct GetConversionConsequences: ServiceRequestPayload {
    public typealias Response = ConversionConsequences
    public static let operation = "getConversionConsequences"
    public static let requiresAccount = true
    public let conversationID: Conversation.ID

    public init(conversationID: Conversation.ID) {
        self.conversationID = conversationID
    }
}
