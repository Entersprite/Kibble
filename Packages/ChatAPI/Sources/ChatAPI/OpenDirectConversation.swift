import ChatKit
import Foundation

public struct OpenDirectConversation: ServiceRequestPayload {
    public typealias Response = Conversation
    public static let operation = "openDirectConversation"
    public static let requiresAccount = true
    public let memberID: Member.ID
    public let operationID: ServiceOperationID

    public init(memberID: Member.ID, operationID: ServiceOperationID) {
        self.memberID = memberID
        self.operationID = operationID
    }
}
