import ChatKit
import Foundation

public struct SetAccountPolicy: ServiceRequestPayload {
    public typealias Response = AccountPolicy
    public static let operation = "setAccountPolicy"
    public static let requiresAccount = true
    public let settings: NotificationSettings
    public let expectedRevision: String

    public init(settings: NotificationSettings, expectedRevision: String) {
        self.settings = settings
        self.expectedRevision = expectedRevision
    }
}
