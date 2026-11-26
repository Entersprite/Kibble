import ChatKit

public struct GetBlockedPeople: ServiceRequestPayload {
    public typealias Response = [BlockedPerson]
    public static let operation = "getBlockedPeople"
    public static let requiresAccount = true

    public init() {}
}

public struct UnblockPerson: ServiceRequestPayload {
    public typealias Response = [BlockedPerson]
    public static let operation = "unblockPerson"
    public static let requiresAccount = true
    public let person: Member.ID
    public let operationID: ServiceOperationID

    public init(person: Member.ID, operationID: ServiceOperationID) {
        self.person = person
        self.operationID = operationID
    }
}
