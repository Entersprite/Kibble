import ChatKit
import Foundation

public struct GetMembership: ServiceRequestPayload {
    public typealias Response = MembershipResult
    public static let operation = "getMembership"
    public static let requiresAccount = true
    public let memberID: Member.ID
    public let conversationID: Conversation.ID

    public init(memberID: Member.ID, conversationID: Conversation.ID) {
        self.memberID = memberID
        self.conversationID = conversationID
    }
}
