import ChatAPI
import ChatService
import Foundation
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// An advisory process lease for one local service directory. Keep the lock
/// inode after release: unlinking it could allow two owners of different inodes.
public struct FileServiceOwnership: ServiceOwnership {
    private let file: URL

    public init(file: URL) throws {
        guard file.isFileURL else { throw ServiceFailure.invalidRequest }
        self.file = file
    }

    public func acquire() throws -> any ServiceOwnershipLease {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = open(
            file.path(percentEncoded: false),
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard descriptor >= 0 else { throw ServiceFailure.internalFailure }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw ServiceFailure.ownerBusy
        }
        return FileLease(descriptor: descriptor)
    }
}

private final class FileLease: ServiceOwnershipLease, @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32?

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    func release() {
        lock.withLock {
            guard let descriptor else { return }
            self.descriptor = nil
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
        }
    }

    deinit { release() }
}
