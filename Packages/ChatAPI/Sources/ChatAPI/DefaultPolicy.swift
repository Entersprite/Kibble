import ChatKit
import Foundation

/// Overall defaults for the authenticated principal, above account overrides.
public struct GetDefaultPolicy: ServiceRequestPayload {
    public typealias Response = AccountPolicy
    public static let operation = "getDefaultPolicy"
    public static let requiresAccount = false
    public init() {}
}

public struct SetDefaultPolicy: ServiceRequestPayload {
    public typealias Response = AccountPolicy
    public static let operation = "setDefaultPolicy"
    public static let requiresAccount = false
    public let rule: NotificationRule
    public let expectedRevision: String

    public init(rule: NotificationRule, expectedRevision: String) {
        self.rule = rule
        self.expectedRevision = expectedRevision
    }
}
