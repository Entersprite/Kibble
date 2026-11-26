import Foundation

/// Progress for a pending Join, scoped to its existing conversation call.
public struct CallAdmission: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let requestPending = CallAdmission(rawValue: "requestPending")
    public static let waitingRoom = CallAdmission(rawValue: "waitingRoom")

    public init(from decoder: any Decoder) throws {
        try self.init(rawValue: WireString.decode(from: decoder))
    }

    public func encode(to encoder: any Encoder) throws {
        try WireString.encode(rawValue, to: encoder)
    }
}
