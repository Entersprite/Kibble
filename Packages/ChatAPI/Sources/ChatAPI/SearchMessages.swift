import ChatKit
import Foundation

public struct SearchMessages: ServiceRequestPayload {
    public typealias Response = MessageSearchPage
    public static let operation = "searchMessages"
    public static let requiresAccount = true
    public let query: MessageSearchQuery
    public let cursor: MessageSearchCursor?

    public init(query: MessageSearchQuery, cursor: MessageSearchCursor?) {
        self.query = query
        self.cursor = cursor
    }
}
