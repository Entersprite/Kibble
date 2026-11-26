import ChatAPI
import Foundation
import Synchronization

final class TransferDiskBudget: Sendable {
    struct Entry: Sendable {
        let account: ConnectedAccountID
        let owner: UUID
        let file: URL
        let bytes: Int
    }

    struct State {
        var owners: [ConnectedAccountID: UUID] = [:]
        var entries: [UUID: Entry] = [:]
        var bytes = 0
        var prepared = false
        var orphans: [String: Int] = [:]
    }

    let maximum: Int
    private let state = Mutex(State())

    init(maximum: Int) {
        self.maximum = max(0, maximum)
    }

    /// A crashed disabled account still occupies disk after this factory restarts.
    /// Charge existing managed files before admitting any new reservation.
    func prepare(_ directory: URL) throws {
        try state.withLock { state in
            guard !state.prepared else { return }
            let folders: [URL]
            do {
                folders = try FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                )
            } catch CocoaError.fileReadNoSuchFile {
                state.prepared = true
                return
            }
            var orphans: [String: Int] = [:]
            var total = 0
            for folder in folders {
                let name = folder.lastPathComponent.replacingOccurrences(of: "_", with: "/")
                    .replacingOccurrences(of: "-", with: "+")
                guard let accountBytes = Data(base64Encoded: name), !accountBytes.isEmpty,
                      accountBytes.count <= 120,
                      String(data: accountBytes, encoding: .utf8) != nil else { continue }
                let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    throw ServiceFailure.invalidRequest
                }
                let files = try FileManager.default.contentsOfDirectory(
                    at: folder,
                    includingPropertiesForKeys: nil
                )
                for file in files where file.lastPathComponent.hasPrefix("spool-") {
                    let values = try file.resourceValues(forKeys: [
                        .isRegularFileKey,
                        .isSymbolicLinkKey,
                        .fileSizeKey
                    ])
                    guard values.isRegularFile == true, values.isSymbolicLink != true,
                          let count = values.fileSize, count >= 0, count <= Int.max - total else {
                        throw ServiceFailure.invalidRequest
                    }
                    orphans[Self.fileKey(file)] = count
                    total += count
                }
            }
            state.orphans = orphans
            state.bytes = total
            state.prepared = true
        }
    }

    func reclaim(_ file: URL) {
        state.withLock { state in
            if let bytes = state.orphans
                .removeValue(forKey: Self.fileKey(file)) {
                state.bytes -= bytes
            }
        }
    }

    private static func fileKey(_ file: URL) -> String {
        file.deletingLastPathComponent().lastPathComponent + "/" + file.lastPathComponent
    }

    func acquire(_ account: ConnectedAccountID) throws -> UUID {
        try state.withLock { state in
            guard state.owners[account] == nil else { throw ServiceFailure.ownerBusy }
            let owner = UUID()
            state.owners[account] = owner
            return owner
        }
    }

    func release(_ account: ConnectedAccountID, owner: UUID) {
        state.withLock { state in
            if state.owners[account] == owner {
                state.owners[account] = nil
            }
        }
    }

    func reserve(account: ConnectedAccountID, owner: UUID, file: URL, bytes: Int) throws -> UUID {
        try state.withLock { state in
            guard state.owners[account] == owner else { throw ServiceFailure.ownerBusy }
            guard bytes >= 0, bytes <= maximum - state.bytes else { throw ServiceFailure.overloaded }
            let id = UUID()
            state.entries[id] = Entry(account: account, owner: owner, file: file, bytes: bytes)
            state.bytes += bytes
            return id
        }
    }

    func release(_ reservation: UUID) {
        state.withLock { state in
            if let entry = state.entries.removeValue(forKey: reservation) {
                state.bytes -= entry.bytes
            }
        }
    }

    func abandonedFiles(_ account: ConnectedAccountID, currentOwner: UUID) -> [UUID: Entry] {
        state.withLock { state in
            state.entries.filter { $0.value.account == account && $0.value.owner != currentOwner }
        }
    }
}
