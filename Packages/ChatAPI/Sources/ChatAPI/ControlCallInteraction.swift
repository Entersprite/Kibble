import ChatKit
import Foundation

public struct ControlCallInteraction: ServiceRequestPayload {
    public typealias Response = ServiceCallState
    public static let operation = "controlCallInteraction"
    public static let requiresAccount = true
    public let callID: UUID
    public let sourceID: UUID
    public let raised: Bool

    public init(callID: UUID, sourceID: UUID, raised: Bool) {
        self.callID = callID
        self.sourceID = sourceID
        self.raised = raised
    }
}
