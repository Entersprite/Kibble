import ChatKit
import Foundation

public struct GetCapabilities: ServiceRequestPayload {
    public typealias Response = Capabilities
    public static let operation = "getCapabilities"
    public static let requiresAccount = true

    public init() {}
}
