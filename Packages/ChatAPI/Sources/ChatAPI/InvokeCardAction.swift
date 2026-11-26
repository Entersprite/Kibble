import ChatKit
import Foundation

public struct InvokeCardAction: ServiceRequestPayload {
    public typealias Response = AppCardActionResult
    public static let operation = "invokeCardAction"
    public static let requiresAccount = true
    public let action: AppCardActionRequest
    public let operationID: ServiceOperationID

    public init(action: AppCardActionRequest, operationID: ServiceOperationID) {
        self.action = action
        self.operationID = operationID
    }
}
