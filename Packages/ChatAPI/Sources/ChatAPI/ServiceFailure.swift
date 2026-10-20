import ChatKit
import Foundation

/// Stable machine-readable failures. Unknown codes retain their structured details.
/// This value carries no arbitrary description from an underlying host error.
public struct ServiceFailure: Error, Codable, Hashable, Sendable {
    public let code: String
    public let details: JSONValue?

    public init(code: String, details: JSONValue? = nil) {
        self.code = code
        self.details = details
    }

    public static let accountCleanupPending = ServiceFailure(code: "accountCleanupPending")
    public static let authenticationRequired = ServiceFailure(code: "authenticationRequired")
    public static let staleAccount = ServiceFailure(code: "staleAccount")
    public static let ownerBusy = ServiceFailure(code: "ownerBusy")
    public static let accountDisabled = ServiceFailure(code: "accountDisabled")
    public static let accountNotFound = ServiceFailure(code: "accountNotFound")
    public static let staleCallSource = ServiceFailure(code: "staleCallSource")
    public static let operationExpired = ServiceFailure(code: "operationExpired")
    public static let operationUnknown = ServiceFailure(code: "operationUnknown")
    public static let operationConflict = ServiceFailure(code: "operationConflict")
    public static let revisionConflict = ServiceFailure(code: "revisionConflict")
    public static let privacyDenied = ServiceFailure(code: "privacyDenied")
    public static let policyUnavailable = ServiceFailure(code: "policyUnavailable")
    public static let clientAttachmentExpired = ServiceFailure(code: "clientAttachmentExpired")
    public static let invalidRequest = ServiceFailure(code: "invalidRequest")
    public static let transferExpired = ServiceFailure(code: "transferExpired")
    public static let deviceBusy = ServiceFailure(code: "deviceBusy")
    public static let incompatibleVersion = ServiceFailure(code: "incompatibleVersion")
    public static let handshakeRequired = ServiceFailure(code: "handshakeRequired")
    public static let notAuthorized = ServiceFailure(code: "notAuthorized")
    public static let accountRequired = ServiceFailure(code: "accountRequired")
    public static let unsupportedOperation = ServiceFailure(code: "unsupportedOperation")
    public static let invalidResponse = ServiceFailure(code: "invalidResponse")
    public static let deadlineExceeded = ServiceFailure(code: "deadlineExceeded")
    public static let frameTooLarge = ServiceFailure(code: "frameTooLarge")
    /// A durable event subscriber must resume from its last committed cursor.
    public static let resynchronizationRequired = ServiceFailure(code: "resynchronizationRequired")
    public static let overloaded = ServiceFailure(code: "overloaded")
    public static let duplicateRequest = ServiceFailure(code: "duplicateRequest")
    public static let internalFailure = ServiceFailure(code: "internalFailure")
}
