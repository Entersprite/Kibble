import ChatKit
import Foundation

public struct BrowseSpaces: ServiceRequestPayload {
    public typealias Response = SpaceDirectoryPage
    public static let operation = "browseSpaces"
    public static let requiresAccount = true
    public let query: SpaceDirectoryQuery
    public let cursor: String?

    public init(query: SpaceDirectoryQuery, cursor: String?) {
        self.query = query
        self.cursor = cursor
    }
}
