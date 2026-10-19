import Foundation

/// Established by a trusted transport host, never decoded from a request.
/// The endpoint must additionally check current authorization and lifecycle.
public struct ServiceSessionContext: Hashable, Sendable {
    public let principalID: ServicePrincipalID
    public let deviceID: ServiceDeviceID
    public let sessionID: ClientSessionID
    public let accounts: Set<ConnectedAccountID>

    public init(
        principalID: ServicePrincipalID, deviceID: ServiceDeviceID,
        sessionID: ClientSessionID, accounts: Set<ConnectedAccountID>
    ) {
        self.principalID = principalID
        self.deviceID = deviceID
        self.sessionID = sessionID
        self.accounts = accounts
    }
}

/// Bytes are the embedded boundary too; native implementation references never
/// become payloads. A server host will establish its own session context.
public protocol ServiceEndpoint: Sendable {
    func handle(_ request: Data, context: ServiceSessionContext) async throws -> Data
}

public protocol ServiceTransport: Sendable {
    func negotiate(_ peer: ServiceAPIVersion) async throws -> ServiceAPIVersion
    func exchange(_ request: ServiceRequest) async throws -> ServiceResponse
}
