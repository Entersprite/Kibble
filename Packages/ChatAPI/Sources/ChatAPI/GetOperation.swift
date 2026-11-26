import ChatKit
import Foundation

public struct GetOperation: ServiceRequestPayload {
    public typealias Response = ServiceOperation
    public static let operation = "getOperation"
    public static let requiresAccount = true
    public let operationID: ServiceOperationID

    public init(operationID: ServiceOperationID) {
        self.operationID = operationID
    }
}
