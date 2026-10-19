import Foundation

/// Stable host identity for separating client replicas and local preferences.
/// This is metadata, never an account grant or an authentication credential.
public struct ServiceInfo: Codable, Hashable, Sendable {
    public let instanceID: ServiceInstanceID
    public init(instanceID: ServiceInstanceID) {
        self.instanceID = instanceID
    }
}

public struct GetServiceInfo: ServiceRequestPayload {
    public typealias Response = ServiceInfo
    public static let operation = "getServiceInfo"
    public static let requiresAccount = false
    public init() {}
}
