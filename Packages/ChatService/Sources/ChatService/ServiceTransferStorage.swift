import ChatAPI
import Foundation

/// Server-owned spool files. These paths never cross the client API.
public protocol ServiceTransferStorage: Sendable {
    func create(_ id: ServiceTransferID, maximumBytes: Int) throws
    func append(_ bytes: Data, to id: ServiceTransferID, at offset: Int64) throws
    func read(_ id: ServiceTransferID, at offset: Int64, count: Int) throws -> Data
    func file(_ id: ServiceTransferID, expectedBytes: Int) throws -> URL
    func remove(_ id: ServiceTransferID) throws
    /// Refused removals retain their reservation and can be retried.
    func close() throws
}

public protocol ServiceTransferStorageFactory: Sendable {
    /// One writer per account; the service must already own its instance directory.
    func open(_ account: ConnectedAccountID) throws -> any ServiceTransferStorage
    func erase(_ account: ConnectedAccountID) throws
}

public struct ServiceTransferLimits: Sendable {
    public let maximumFileBytes: Int
    public let maximumAccountBytes: Int
    public let maximumAccountTransfers: Int
    public let lifetime: TimeInterval

    public init(
        maximumFileBytes: Int = 128 * 1024 * 1024,
        maximumAccountBytes: Int = 512 * 1024 * 1024,
        maximumAccountTransfers: Int = 8,
        lifetime: TimeInterval = 15 * 60
    ) {
        self.maximumFileBytes = max(0, maximumFileBytes)
        self.maximumAccountBytes = max(0, maximumAccountBytes)
        self.maximumAccountTransfers = max(0, maximumAccountTransfers)
        self.lifetime = lifetime.isFinite ? max(1, min(3600, lifetime)) : 900
    }
}

/// The provider opens a reserved nonexisting destination exclusively.
public protocol ServiceDownloadStorage: ServiceTransferStorage {
    func reserveDownload(_ id: ServiceTransferID, maximumBytes: Int) throws -> URL
    func completeDownload(_ id: ServiceTransferID) throws -> Int
}
