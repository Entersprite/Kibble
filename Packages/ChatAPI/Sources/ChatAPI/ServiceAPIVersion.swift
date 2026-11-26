import Foundation

/// Independent from the domain event/command schema version.
public struct ServiceAPIVersion: Codable, Hashable, Sendable {
    public let major: UInt
    public let minor: UInt

    public static let current = ServiceAPIVersion(major: 1, minor: 0)

    public init(major: UInt, minor: UInt) {
        self.major = major
        self.minor = minor
    }

    /// Minor additions are optional; incompatible major versions are refused.
    public func negotiated(with peer: ServiceAPIVersion) throws -> ServiceAPIVersion {
        guard major == peer.major else { throw ServiceFailure.incompatibleVersion }
        return ServiceAPIVersion(major: major, minor: min(minor, peer.minor))
    }
}
