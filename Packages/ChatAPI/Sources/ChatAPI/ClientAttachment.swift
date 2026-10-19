import Foundation

/// A short-lived interest lease, bound to account revision and trusted device/
/// client session. The opaque token is never a grant by itself.
public struct ClientAttachment: Codable, Hashable, Sendable {
    public let id: ClientAttachmentID
    public let expiresAt: Date
    public init(id: ClientAttachmentID, expiresAt: Date) {
        self.id = id; self.expiresAt = expiresAt
    }
}

public struct AttachAccountClient: ServiceRequestPayload {
    public typealias Response = ClientAttachment
    public static let operation = "attachAccountClient"
    public static let requiresAccount = true
    /// Canonical positive UInt64 text. Increasing generations replace earlier
    /// interests; renewing the same live generation preserves them.
    public let generation: String
    public init(generation: String) {
        self.generation = generation
    }
}

public struct DetachAccountClient: ServiceRequestPayload {
    public typealias Response = ServiceUnit
    public static let operation = "detachAccountClient"
    public static let requiresAccount = true
    public let attachmentID: ClientAttachmentID
    public init(attachmentID: ClientAttachmentID) {
        self.attachmentID = attachmentID
    }
}
