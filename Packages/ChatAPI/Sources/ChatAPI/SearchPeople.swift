import ChatKit
import Foundation

public struct SearchPeople: ServiceRequestPayload {
    public typealias Response = [Member]
    public static let operation = "searchPeople"
    public static let requiresAccount = true
    public let query: String

    public init(query: String) {
        self.query = query
    }
}
