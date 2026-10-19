import Foundation

/// Account and stream identity are inseparable from sequence. Decimal strings
/// keep Int64-sized sequences exact even when a frame passes through JSONValue.
public struct ServiceCursor: Codable, Hashable, Sendable {
    public let accountID: ConnectedAccountID
    public let streamID: ServiceStreamID
    public let sequence: UInt64

    public init(accountID: ConnectedAccountID, streamID: ServiceStreamID, sequence: UInt64) {
        self.accountID = accountID
        self.streamID = streamID
        self.sequence = sequence
    }

    private enum CodingKeys: String, CodingKey {
        case accountID, streamID, sequence
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountID = try container.decode(ConnectedAccountID.self, forKey: .accountID)
        streamID = try container.decode(ServiceStreamID.self, forKey: .streamID)
        let raw = try container.decode(String.self, forKey: .sequence)
        guard let sequence = UInt64(raw), String(sequence) == raw else {
            throw DecodingError.dataCorruptedError(
                forKey: .sequence, in: container, debugDescription: "Invalid sequence"
            )
        }
        self.sequence = sequence
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accountID, forKey: .accountID)
        try container.encode(streamID, forKey: .streamID)
        try container.encode(String(sequence), forKey: .sequence)
    }
}
