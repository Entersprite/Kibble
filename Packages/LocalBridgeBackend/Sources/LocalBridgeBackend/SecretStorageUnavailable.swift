import Foundation

/// A host vault refused access. It is not evidence of an absent credential.
public struct SecretStorageUnavailable: Error, Sendable, Hashable {
    public let status: Int

    public init(status: Int) {
        self.status = status
    }
}
