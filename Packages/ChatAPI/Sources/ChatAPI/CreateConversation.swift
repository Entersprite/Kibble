import ChatKit
import Foundation

public struct CreateConversation: ServiceRequestPayload {
    public typealias Response = ConversationCreationResult
    public static let operation = "createConversation"
    public static let requiresAccount = true
    public let draft: ConversationDraft
    public let operationID: ServiceOperationID

    public init(draft: ConversationDraft, operationID: ServiceOperationID) {
        self.draft = draft
        self.operationID = operationID
    }
}
