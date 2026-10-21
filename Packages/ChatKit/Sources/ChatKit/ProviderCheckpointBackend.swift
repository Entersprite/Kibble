import Foundation

/// Trusted provider/service delivery. This is separate from client replica cursors.
public struct ProviderEventBatch: Codable, Hashable, Sendable {
    public let id: String
    public let events: [ChatEvent]
    public let directory: ConversationSnapshot?
    public let invalidatesHistory: Bool
    public let directoryReadBegan: Bool
    public let previousCheckpoint: Data?
    public let checkpoint: Data?
    public let isLive: Bool

    public init(
        id: String, events: [ChatEvent], directory: ConversationSnapshot? = nil,
        invalidatesHistory: Bool = false, directoryReadBegan: Bool = false, previousCheckpoint: Data?,
        checkpoint: Data?, isLive: Bool = false
    ) {
        self.id = id
        self.events = events
        self.directory = directory
        self.invalidatesHistory = invalidatesHistory
        self.directoryReadBegan = directoryReadBegan
        self.previousCheckpoint = previousCheckpoint
        self.checkpoint = checkpoint
        self.isLive = isLive
    }

    private enum CodingKeys: String, CodingKey {
        case id, events, directory, invalidatesHistory, directoryReadBegan, previousCheckpoint, checkpoint,
             isLive
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(String.self, forKey: .id), events: values.decode(
                [ChatEvent].self,
                forKey: .events
            ),
            directory: values.decodeIfPresent(ConversationSnapshot.self, forKey: .directory),
            invalidatesHistory: values.decodeIfPresent(Bool.self, forKey: .invalidatesHistory) ?? false,
            directoryReadBegan: values.decodeIfPresent(Bool.self, forKey: .directoryReadBegan) ?? false,
            previousCheckpoint: values.decodeIfPresent(Data.self, forKey: .previousCheckpoint),
            checkpoint: values.decodeIfPresent(Data.self, forKey: .checkpoint),
            isLive: values.decodeIfPresent(Bool.self, forKey: .isLive) ?? false
        )
    }
}

/// An enabled provider has one batch consumer. Immutable batch IDs bind retries;
/// acknowledgement follows canonical commit, never socket receipt.
public protocol ProviderCheckpointBackend: ChatBackend {
    var providerEventBatches: AsyncStream<ProviderEventBatch> { get }
    func usesProviderCheckpoints() async -> Bool
    func connect(resumingProviderCheckpoint: Data?) async throws
    func acknowledgeProviderBatch(_ id: String) async
}
