import ChatKit
import Foundation

public struct LoadFollowedThreads: ServiceRequestPayload {
    public typealias Response = [Message]
    public static let operation = "loadFollowedThreads"
    public static let requiresAccount = true

    public init() {}
}
