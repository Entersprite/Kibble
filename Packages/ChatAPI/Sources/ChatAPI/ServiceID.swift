import Foundation

/// Opaque identifiers remain distinct at compile time and encode as strings.
/// Possession of an identifier never grants access to its resource.
public struct ServiceID<Scope: Sendable>: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum ConnectedAccountScope: Sendable {}
public enum ServiceInstanceScope: Sendable {}
public enum ServicePrincipalScope: Sendable {}
public enum ServiceDeviceScope: Sendable {}
public enum ClientSessionScope: Sendable {}
public enum ServiceRequestScope: Sendable {}
public enum ServiceOperationScope: Sendable {}
public enum ServiceSubscriptionScope: Sendable {}
public enum ServiceStreamScope: Sendable {}

public typealias ConnectedAccountID = ServiceID<ConnectedAccountScope>
public typealias ServiceInstanceID = ServiceID<ServiceInstanceScope>
public typealias ServicePrincipalID = ServiceID<ServicePrincipalScope>
public typealias ServiceDeviceID = ServiceID<ServiceDeviceScope>
public typealias ClientSessionID = ServiceID<ClientSessionScope>
public typealias ServiceRequestID = ServiceID<ServiceRequestScope>
public typealias ServiceOperationID = ServiceID<ServiceOperationScope>
public typealias ServiceSubscriptionID = ServiceID<ServiceSubscriptionScope>
public typealias ServiceStreamID = ServiceID<ServiceStreamScope>
