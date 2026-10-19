import ChatKit
import Foundation

public struct SetAccountEnabled: ServiceRequestPayload {
    public typealias Response = AccountSummary
    public static let operation = "setAccountEnabled"
    public static let requiresAccount = true
    public let enabled: Bool

    public init(enabled: Bool) {
        self.enabled = enabled
    }
}
