import Foundation

public struct RetryAccountRecovery: ServiceRequestPayload {
    public typealias Response = AccountSummary
    public static let operation = "retryAccountRecovery"
    public static let requiresAccount = true
    public init() {}
}
