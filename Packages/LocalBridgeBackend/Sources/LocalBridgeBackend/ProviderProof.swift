import Foundation

/// Injected computation for an existing provider authentication protocol.
public struct ProviderProof: Sendable {
    public let sha1Hex: @Sendable (String) -> String

    public init(sha1Hex: @escaping @Sendable (String) -> String) {
        self.sha1Hex = sha1Hex
    }

    public static let portable = ProviderProof(sha1Hex: SHA1.hex)
}
