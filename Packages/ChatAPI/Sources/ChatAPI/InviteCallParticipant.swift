import ChatKit
import Foundation

public struct InviteCallParticipant: ServiceRequestPayload {
    public typealias Response = ServiceCallState
    public static let operation = "inviteCallParticipant"
    public static let requiresAccount = true
    public let callID: UUID
    public let sourceID: UUID
    public let memberID: Member.ID
    public let invitationID: UUID

    public init(callID: UUID, sourceID: UUID, memberID: Member.ID, invitationID: UUID = UUID()) {
        self.invitationID = invitationID
        self.callID = callID
        self.sourceID = sourceID
        self.memberID = memberID
    }
}
