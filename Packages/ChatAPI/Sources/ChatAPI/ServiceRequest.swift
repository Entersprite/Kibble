import ChatKit
import Foundation

public protocol ServiceRequestPayload: Codable, Hashable, Sendable {
    associatedtype Response: Codable & Hashable & Sendable
    static var operation: String { get }
    static var requiresAccount: Bool { get }
}

public struct ServiceRequestHeader: Codable, Hashable, Sendable {
    public let version: ServiceAPIVersion
    public let requestID: ServiceRequestID
    public let accountID: ConnectedAccountID?
    public let deadline: Date?

    public init(
        requestID: ServiceRequestID,
        accountID: ConnectedAccountID? = nil,
        deadline: Date? = nil,
        version: ServiceAPIVersion = .current
    ) {
        self.version = version
        self.requestID = requestID
        self.accountID = accountID
        self.deadline = deadline
    }
}

/// Dispatchable bytes retain unknown request payloads until an endpoint either
/// recognizes the operation or explicitly refuses it. No caller identity is encoded.
public struct ServiceRequest: Codable, Hashable, Sendable {
    public let header: ServiceRequestHeader
    public let operation: String
    public let payload: JSONValue

    public init(header: ServiceRequestHeader, operation: String, payload: JSONValue) {
        self.header = header
        self.operation = operation
        self.payload = payload
    }

    public init(header: ServiceRequestHeader, payload: some ServiceRequestPayload) throws {
        try Self.checkScope(type(of: payload), header: header)
        self.header = header
        operation = type(of: payload).operation
        self.payload = try ServiceCodec.value(payload)
    }

    /// Endpoint dispatch rechecks the operation's required account scope instead
    /// of trusting that the peer used the typed request initializer.
    public func decodePayload<Payload: ServiceRequestPayload>(_ type: Payload.Type) throws -> Payload {
        guard operation == type.operation else { throw ServiceFailure.unsupportedOperation }
        try Self.checkScope(type, header: header)
        return try ServiceCodec.decode(type, from: payload)
    }

    private static func checkScope(
        _ type: (some ServiceRequestPayload).Type,
        header: ServiceRequestHeader
    ) throws {
        if type.requiresAccount, header.accountID == nil {
            throw ServiceFailure.accountRequired
        }
        if !type.requiresAccount, header.accountID != nil {
            throw ServiceFailure.notAuthorized
        }
    }
}
