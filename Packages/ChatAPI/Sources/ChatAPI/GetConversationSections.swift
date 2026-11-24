import ChatKit

public struct GetConversationSections: ServiceRequestPayload {
    public typealias Response = ConversationSectionsResult
    public static let operation = "getConversationSections"
    public static let requiresAccount = true

    public init() {}
}

public struct ConversationSectionsResult: Codable, Hashable, Sendable {
    public let sections: [ConversationSection]?

    public init(sections: [ConversationSection]?) {
        self.sections = sections
    }
}

public struct UpdateConversationSection: ServiceRequestPayload {
    public typealias Response = ServiceUnit
    public static let operation = "updateConversationSection"
    public static let requiresAccount = true

    public let edit: ConversationSectionEdit
    public let operationID: ServiceOperationID

    public init(edit: ConversationSectionEdit, operationID: ServiceOperationID) {
        self.edit = edit
        self.operationID = operationID
    }
}
