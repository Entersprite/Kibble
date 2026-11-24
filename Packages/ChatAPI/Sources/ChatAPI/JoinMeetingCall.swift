import ChatKit
import Foundation

/// Explicit account-scoped creation of a link, independent of call admission.
public struct CreateMeetingLink: ServiceRequestPayload {
    public typealias Response = URL
    public static let operation = "createMeetingLink"
    public static let requiresAccount = true
    public let requestID: UUID
    public let sourceID: UUID

    public init(requestID: UUID, sourceID: UUID) {
        self.requestID = requestID
        self.sourceID = sourceID
    }
}

/// Optional display metadata for a link, independent of call admission.
public struct PreviewMeetingLink: ServiceRequestPayload {
    public typealias Response = String?
    public static let operation = "previewMeetingLink"
    public static let requiresAccount = true
    public let url: URL
    public let sourceID: UUID

    public init(url: URL, sourceID: UUID) {
        self.url = url
        self.sourceID = sourceID
    }
}

/// Explicit ephemeral join, bound to the trusted account/device and current
/// call source. It never enters the durable command ledger or rings anyone.
public struct JoinMeetingCall: ServiceRequestPayload {
    public typealias Response = ServiceCallState
    public static let operation = "joinMeetingCall"
    public static let requiresAccount = true
    public let url: URL
    public let callID: UUID
    public let sourceID: UUID

    public init(url: URL, callID: UUID, sourceID: UUID) {
        self.url = url
        self.callID = callID
        self.sourceID = sourceID
    }
}
