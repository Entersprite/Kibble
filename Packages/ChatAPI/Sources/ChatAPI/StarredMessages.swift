import ChatKit

public struct GetStarredMessages: ServiceRequestPayload {
    public typealias Response = StarredMessagesPage
    public static let operation = "getStarredMessages"
    public static let requiresAccount = true
    public let cursor: String?

    public init(cursor: String?) {
        self.cursor = cursor
    }
}

public struct SetMessageStarred: ServiceRequestPayload {
    public typealias Response = ServiceUnit
    public static let operation = "setMessageStarred"
    public static let requiresAccount = true
    public let address: MessageAddress
    public let starred: Bool
    public let operationID: ServiceOperationID

    public init(address: MessageAddress, starred: Bool, operationID: ServiceOperationID) {
        self.address = address
        self.starred = starred
        self.operationID = operationID
    }
}
