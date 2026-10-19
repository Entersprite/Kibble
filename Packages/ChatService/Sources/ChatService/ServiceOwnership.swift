import Foundation

/// A host grants one service owner at a time. Hosts can supply their own
/// lease implementation without changing client protocols.
public protocol ServiceOwnership: Sendable {
    func acquire() throws -> any ServiceOwnershipLease
}

public protocol ServiceOwnershipLease: AnyObject, Sendable {
    /// Idempotent. Release only after every owned runtime/lifecycle job drains.
    func release()
}
