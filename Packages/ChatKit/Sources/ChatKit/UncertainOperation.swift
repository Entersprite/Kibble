import Foundation

/// Dispatch may have reached the provider. A new operation is not a safe retry.
public struct UncertainOperation: Error, Codable, Hashable, Sendable {
    public let operationID: String

    public init(operationID: String) {
        self.operationID = operationID
    }
}
