import Foundation

/// A provider-neutral replica position. Account and stream are opaque namespaces.
public struct ReplicaCheckpoint: Codable, Hashable, Sendable {
    public let account: String
    public let stream: String
    public let sequence: UInt64

    public init(account: String, stream: String, sequence: UInt64) {
        self.account = account
        self.stream = stream
        self.sequence = sequence
    }

    private enum CodingKeys: String, CodingKey { case account, stream, sequence }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        account = try values.decode(String.self, forKey: .account)
        stream = try values.decode(String.self, forKey: .stream)
        let raw = try values.decode(String.self, forKey: .sequence)
        guard let sequence = UInt64(raw), String(sequence) == raw else {
            throw DecodingError.dataCorruptedError(
                forKey: .sequence,
                in: values,
                debugDescription: "Invalid checkpoint"
            )
        }
        self.sequence = sequence
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(account, forKey: .account)
        try values.encode(stream, forKey: .stream)
        try values.encode(String(sequence), forKey: .sequence)
    }
}

public struct ChatDelivery: Codable, Hashable, Sendable {
    public let checkpoint: ReplicaCheckpoint?
    public let events: [ChatEvent]
    public let isSnapshot: Bool
    public let isLive: Bool

    public init(checkpoint: ReplicaCheckpoint?, events: [ChatEvent], isSnapshot: Bool, isLive: Bool) {
        self.checkpoint = checkpoint
        self.events = events
        self.isSnapshot = isSnapshot
        self.isLive = isLive
    }
}

/// Optional ordered delivery capability. A consumer selects this OR `events`.
/// Applied positions advance only after the replica commits the associated writes.
public protocol CheckpointedChatBackend: ChatBackend {
    func useCheckpointedDeliveries(after checkpoint: ReplicaCheckpoint?) async -> AsyncStream<ChatDelivery>
    func acknowledge(_ checkpoint: ReplicaCheckpoint, applied: Bool) async
}
