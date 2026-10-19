import ChatKit
import Foundation

public struct RemoveAccount: ServiceRequestPayload {
    public typealias Response = ServiceUnit
    public static let operation = "removeAccount"
    public static let requiresAccount = true

    public init() {}
}
