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

    public static let incompatibleVersion = ServiceFailure(code: "incompatibleVersion")
    public static let handshakeRequired = ServiceFailure(code: "handshakeRequired")
    public static let notAuthorized = ServiceFailure(code: "notAuthorized")
    public static let accountRequired = ServiceFailure(code: "accountRequired")
    public static let unsupportedOperation = ServiceFailure(code: "unsupportedOperation")
    public static let invalidResponse = ServiceFailure(code: "invalidResponse")
    public static let deadlineExceeded = ServiceFailure(code: "deadlineExceeded")
    public static let frameTooLarge = ServiceFailure(code: "frameTooLarge")
    public static let overloaded = ServiceFailure(code: "overloaded")
    public static let duplicateRequest = ServiceFailure(code: "duplicateRequest")
    public static let internalFailure = ServiceFailure(code: "internalFailure")
}
