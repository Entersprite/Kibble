import ChatKit
import Foundation

/// Queries only the authenticated account's retained canonical history.
/// This is not active-call discovery or a complete provider call log.
public struct ReadCallHistory: ServiceRequestPayload {
    public typealias Response = CallHistoryPage
    public static let operation = "readCallHistory"
    public static let requiresAccount = true
    public let query: CallHistoryQuery

    public init(query: CallHistoryQuery = .init()) {
        self.query = query
    }
}
