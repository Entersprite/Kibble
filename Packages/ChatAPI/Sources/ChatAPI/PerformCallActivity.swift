import ChatKit
import Foundation

public struct PerformCallActivity: ServiceRequestPayload {
    public typealias Response = ServiceCallState
    public static let operation = "performCallActivity"
    public static let requiresAccount = true
    public let callID: UUID
    public let sourceID: UUID
    public let requestID: UUID
    public let activity: CallActivity
    public init(callID: UUID, sourceID: UUID, requestID: UUID = UUID(), activity: CallActivity) {
        self.callID = callID; self.sourceID = sourceID; self.requestID = requestID; self.activity = activity
    }
}
