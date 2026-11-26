import ChatAPI
import ChatKit
import Foundation

/// The checkpoint and all canonical events in a batch share one durable commit.
public protocol ServiceProviderCheckpointStorage: ServiceAccountStorage {
    func providerCheckpoint() throws -> Data?
    func appendProviderBatch(_ batch: ProviderEventBatch, canonicalEvents: [ChatEvent]) throws
        -> ServiceEventPage
}
