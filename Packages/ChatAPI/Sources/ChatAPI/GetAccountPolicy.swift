import ChatKit
import Foundation

public struct GetAccountPolicy: ServiceRequestPayload {
    public typealias Response = AccountPolicy
    public static let operation = "getAccountPolicy"
    public static let requiresAccount = true

    public init() {}
}
