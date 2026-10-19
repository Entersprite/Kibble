import ChatAPI
import ChatService
import Foundation
import Synchronization

/// Quota and writer ownership are shared by every copy of this host factory.
public struct DirectoryTransferStorageFactory: ServiceTransferStorageFactory {
    private let directory: URL
    private let budget: TransferDiskBudget

    public init(directory: URL, maximumReservedBytes: Int = 1024 * 1024 * 1024) {
        self.directory = directory
        budget = TransferDiskBudget(maximum: maximumReservedBytes)
    }

    public func erase(_ account: ConnectedAccountID) throws {
        try open(account).close()
    }

    public func open(_ account: ConnectedAccountID) throws -> any ServiceTransferStorage {
        let data = Data(account.rawValue.utf8)
        guard !data.isEmpty, data.count <= 120 else { throw ServiceFailure.invalidRequest }
        let name = data.base64EncodedString().replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
        let folder = directory.appendingPathComponent(name, isDirectory: true)
        try budget.prepare(directory)
        let owner = try budget.acquire(account)
        do {
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
            let values = try folder.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw ServiceFailure.invalidRequest
            }
            // No prior transfer handle survives a service/runtime restart.
            // Reclaim only this factory's dedicated spool files under ownership.
            for file in try FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil
            ) where file.lastPathComponent.hasPrefix("spool-") {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw ServiceFailure.invalidRequest
                }
                try FileManager.default.removeItem(at: file)
                budget.reclaim(file)
            }
            for (reservation, _) in budget.abandonedFiles(account, currentOwner: owner) {
                budget.release(reservation)
            }
            return DirectoryTransferStorage(folder: folder, account: account, owner: owner, budget: budget)
        } catch {
            budget.release(account, owner: owner)
            throw error
        }
    }
}

private final class DirectoryTransferStorage: ServiceDownloadStorage, Sendable {
    struct File: Sendable {
        let url: URL
        let maximum: Int
        let reservation: UUID
    }

    struct State {
        var files: [ServiceTransferID: File] = [:]
        var closed = false
    }

    let folder: URL
    let account: ConnectedAccountID
    let owner: UUID
    let budget: TransferDiskBudget
    let state = Mutex(State())

    init(folder: URL, account: ConnectedAccountID, owner: UUID, budget: TransferDiskBudget) {
        self.folder = folder
        self.account = account
        self.owner = owner
        self.budget = budget
    }

    deinit { budget.release(account, owner: owner) }

    func create(_ id: ServiceTransferID, maximumBytes: Int) throws {
        try state.withLock { state in
            guard !state.closed else { throw ServiceFailure.accountDisabled }
            guard state.files[id] == nil else { throw ServiceFailure.operationConflict }
            let url = folder.appendingPathComponent("spool-\(UUID().uuidString)")
            let reservation = try budget.reserve(
                account: account,
                owner: owner,
                file: url,
                bytes: maximumBytes
            )
            do {
                try Data().write(to: url, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                // Keep a created file charged if cleanup itself is refused.
                state.files[id] = File(url: url, maximum: maximumBytes, reservation: reservation)
                do { try remove(id, state: &state) } catch { throw ServiceFailure.internalFailure }
                throw error
            }
            state.files[id] = File(url: url, maximum: maximumBytes, reservation: reservation)
        }
    }

    func reserveDownload(_ id: ServiceTransferID, maximumBytes: Int) throws -> URL {
        try state.withLock { state in
            guard !state.closed else { throw ServiceFailure.accountDisabled }
            guard state.files[id] == nil else { throw ServiceFailure.operationConflict }
            let url = folder.appendingPathComponent("spool-\(UUID().uuidString)")
            let reservation = try budget.reserve(
                account: account,
                owner: owner,
                file: url,
                bytes: maximumBytes
            )
            state.files[id] = File(url: url, maximum: maximumBytes, reservation: reservation)
            return url
        }
    }

    func completeDownload(_ id: ServiceTransferID) throws -> Int {
        try state.withLock { state in
            let file = try file(id, state: state)
            let handle = try FileHandle(forReadingFrom: file.url)
            defer { try? handle.close() }
            let count = try handle.seekToEnd()
            guard count <= UInt64(file.maximum) else { throw ServiceFailure.frameTooLarge }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.url.path)
            return Int(count)
        }
    }

    func append(_ bytes: Data, to id: ServiceTransferID, at offset: Int64) throws {
        try state.withLock { state in
            let file = try file(id, state: state)
            guard offset >= 0, bytes.count <= ServiceBinaryLimits.maximumChunkBytes,
                  offset <= Int64(file.maximum) - Int64(bytes.count) else {
                throw ServiceFailure.invalidRequest
            }
            let handle = try FileHandle(forWritingTo: file.url)
            defer { try? handle.close() }
            guard try handle.seekToEnd() == UInt64(offset) else { throw ServiceFailure.operationConflict }
            try handle.write(contentsOf: bytes)
        }
    }

    func read(_ id: ServiceTransferID, at offset: Int64, count: Int) throws -> Data {
        try state.withLock { state in
            let file = try file(id, state: state)
            guard offset >= 0, count >= 0, count <= ServiceBinaryLimits.maximumChunkBytes,
                  offset <= Int64(file.maximum) else { throw ServiceFailure.invalidRequest }
            let handle = try FileHandle(forReadingFrom: file.url)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: count) ?? Data()
        }
    }

    func file(_ id: ServiceTransferID, expectedBytes: Int) throws -> URL {
        try state.withLock { state in
            let file = try file(id, state: state)
            let handle = try FileHandle(forReadingFrom: file.url)
            defer { try? handle.close() }
            let count = try handle.seekToEnd()
            guard expectedBytes >= 0, expectedBytes <= file.maximum, count == UInt64(expectedBytes) else {
                throw ServiceFailure.operationConflict
            }
            return file.url
        }
    }

    func remove(_ id: ServiceTransferID) throws {
        try state.withLock { state in try remove(id, state: &state) }
    }

    func close() throws {
        try state.withLock { state in
            state.closed = true
            var failure: (any Error)?
            for id in Array(state.files.keys) {
                do {
                    try remove(id, state: &state)
                } catch {
                    failure = failure ?? error
                }
            }
            if let failure {
                throw failure
            }
            budget.release(account, owner: owner)
        }
    }

    private func file(_ id: ServiceTransferID, state: State) throws -> File {
        guard !state.closed, let file = state.files[id] else { throw ServiceFailure.transferExpired }
        let values = try file.url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ServiceFailure.invalidRequest
        }
        return file
    }

    private func remove(_ id: ServiceTransferID, state: inout State) throws {
        guard let file = state.files[id] else { return }
        do {
            try FileManager.default.removeItem(at: file.url)
        } catch CocoaError.fileNoSuchFile {
            // Already absent releases its reservation.
        }
        state.files[id] = nil
        budget.release(file.reservation)
    }
}
