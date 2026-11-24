import ChatKit

public struct CreateConversationSection: ServiceRequestPayload {
    public typealias Response = ConversationSection
    public static let operation = "createConversationSection"
    public static let requiresAccount = true

    public let name: String
    public let operationID: ServiceOperationID

    public init(name: String, operationID: ServiceOperationID) {
        self.name = name
        self.operationID = operationID
    }
}

public struct DeleteConversationSection: ServiceRequestPayload {
    public typealias Response = ServiceUnit
    public static let operation = "deleteConversationSection"
    public static let requiresAccount = true

    public let id: String
    public let operationID: ServiceOperationID

    public init(id: String, operationID: ServiceOperationID) {
        self.id = id
        self.operationID = operationID
    }
}

public struct MoveConversationToSection: ServiceRequestPayload {
    public typealias Response = ServiceUnit
    public static let operation = "moveConversationToSection"
    public static let requiresAccount = true

    public let placement: ConversationSectionPlacement
    public let operationID: ServiceOperationID

    public init(placement: ConversationSectionPlacement, operationID: ServiceOperationID) {
        self.placement = placement
        self.operationID = operationID
    }
}
