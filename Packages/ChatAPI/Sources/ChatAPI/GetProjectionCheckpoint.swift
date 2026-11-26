import Foundation

public struct GetProjectionCheckpoint: ServiceRequestPayload {
    public typealias Response = ServiceCursor
    public static let operation = "getProjectionCheckpoint"
    public static let requiresAccount = true
    public init() {}
}
