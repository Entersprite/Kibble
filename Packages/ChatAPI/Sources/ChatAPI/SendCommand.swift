import ChatKit
import Foundation

public struct SendCommand: ServiceRequestPayload {
    public typealias Response = ServiceOperation
    public static let operation = "sendCommand"
    public static let requiresAccount = true
    public let operationID: ServiceOperationID
    public let command: ChatCommand

    public init(operationID: ServiceOperationID, command: ChatCommand) {
        self.operationID = operationID
        self.command = command
    }
}
