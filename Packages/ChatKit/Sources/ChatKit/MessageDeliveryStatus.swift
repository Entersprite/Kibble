import Foundation

/// Client-side delivery knowledge. An unfamiliar state remains unconfirmed and
/// must never authorize sending the same message as a new operation.
public struct MessageDeliveryStatus: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let sending = Self(rawValue: "sending")
    public static let unconfirmed = Self(rawValue: "unconfirmed")
    public static let sent = Self(rawValue: "sent")
    public static let failed = Self(rawValue: "failed")
    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Read-only reconciliation of a message's original stable client ID. Checking
/// status never submits or retries a provider operation.
public protocol MessageDeliveryTrackingBackend: ChatBackend {
    func deliveryStatus(for localID: String) async throws -> MessageDeliveryStatus
}
