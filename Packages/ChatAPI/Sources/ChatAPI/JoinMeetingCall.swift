import ChatKit
import Foundation

/// Explicit ephemeral join, bound to the trusted account/device and current
/// call source. It never enters the durable command ledger or rings anyone.
public struct JoinMeetingCall: ServiceRequestPayload {
    public typealias Response = ServiceCallState
    public static let operation = "joinMeetingCall"
    public static let requiresAccount = true
    public let url: URL
    public let callID: UUID
    public let sourceID: UUID

    public init(url: URL, callID: UUID, sourceID: UUID) {
        self.url = url
        self.callID = callID
        self.sourceID = sourceID
    }
}
