import ChatKit
import Foundation

public struct SendCommand: ServiceRequestPayload {
    public typealias Response = ServiceOperation
    public static let operation = "sendCommand"
    public static let requiresAccount = true
    public let operationID: ServiceOperationID
    public let command: ChatCommand
    public let draft: SyncedDraft?

    public init(operationID: ServiceOperationID, command: ChatCommand, draft: SyncedDraft? = nil) {
        self.operationID = operationID
        self.command = command
        self.draft = draft
    }
}

public struct SendCommandReceipt: Codable, Hashable, Sendable {
    public let draftConsumed: Bool?

    public init(draftConsumed: Bool? = nil) {
        self.draftConsumed = draftConsumed
    }
}
