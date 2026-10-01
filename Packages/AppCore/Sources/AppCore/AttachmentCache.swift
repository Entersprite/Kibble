import ChatKit
import CryptoKit
import Foundation

/// Attachment bytes this client has already fetched: memory first, then disk,
/// then the backend, with one fetch shared by every simultaneous request.
///
/// ## Why images reach disk at all
///
/// `URLSessionTransport` turns `URLCache` off "because responses carry message
/// content and none of it should reach disk". The store already keeps message
/// text on disk, so the rule that is actually kept is narrower: **content
/// reaches disk only in custody this app can erase.** This is that custody.
/// `erase()` empties it, `ChatSessionModel`'s owner calls it on sign-out, and
/// `LaunchServices.eraseStore()` removes the directory for the path that runs
/// with no session.
///
/// ## Layout
///
/// One directory per entry, named by the SHA-256 of the size and the
/// attachment's id (a 688-character token on the live account,
/// `findings.md` §51.1, far past a file name's limit), holding one file named
/// for the attachment. The name is what Quick Look shows in its title bar and
/// what its extension tells it the type is.
///
/// Lives in AppCore rather than `SyncEngine` because it is client custody,
/// beside the sign-out erase it depends on, and because `SyncEngine` must stay
/// linkable by a future bridge server where CryptoKit does not exist.
public actor AttachmentCache {
    public typealias Fetch = @Sendable (Attachment, AttachmentSize) async throws -> Data

    /// `originalFile(for:)` without a directory: there is nowhere to put a file.
    public struct NoDirectory: Error {}

    private let directory: URL?
    private let capacity: Int
    private let fetch: Fetch
    private let memory = NSCache<NSString, NSData>()
    private var inFlight: [String: Task<Data, any Error>] = [:]

    /// Bumped by `erase()`. A fetch that started under an older generation
    /// still answers its caller but writes nothing: the account it belonged to
    /// has been signed out of.
    private var generation = 0

    /// `capacity` bounds the disk, in bytes; the oldest entries go first. One
    /// entry larger than the whole cap is kept anyway, because the file it
    /// just wrote may be the one Quick Look is about to open.
    public init(directory: URL?, capacity: Int = 200 * 1_048_576, fetch: @escaping Fetch) {
        self.directory = directory
        self.capacity = capacity
        self.fetch = fetch
        memory.totalCostLimit = 64 * 1_048_576
    }

    public func data(for attachment: Attachment, size: AttachmentSize) async throws -> Data {
        let key = Self.key(attachment, size)
        if let hit = memory.object(forKey: key as NSString) {
            return hit as Data
        }
        if let stored = readFromDisk(key) {
            remember(stored, key)
            return stored
        }
        if let running = inFlight[key] {
            return try await running.value
        }
        let started = generation
        let task = Task { [fetch] in try await fetch(attachment, size) }
        inFlight[key] = task
        do {
            let data = try await task.value
            guard started == generation else { return data }
            inFlight[key] = nil
            remember(data, key)
            writeToDisk(data, key, name: Self.fileName(for: attachment))
            return data
        } catch {
            if started == generation {
                inFlight[key] = nil
            }
            throw error
        }
    }

    /// The full-size image as a file, for Quick Look.
    public func originalFile(for attachment: Attachment) async throws -> URL {
        guard directory != nil else { throw NoDirectory() }
        let key = Self.key(attachment, .original)
        let data = try await data(for: attachment, size: .original)
        if let existing = storedFile(key) {
            return existing
        }
        // Memory had it but the disk did not, or the write failed: try once
        // more, and report the failure this time.
        guard let written = writeToDisk(data, key, name: Self.fileName(for: attachment)) else {
            throw NoDirectory()
        }
        return written
    }

    /// Everything, from memory and disk, and every fetch still running is
    /// disowned.
    public func erase() {
        generation += 1
        for task in inFlight.values {
            task.cancel()
        }
        inFlight = [:]
        memory.removeAllObjects()
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Names

    static func key(_ attachment: Attachment, _ size: AttachmentSize) -> String {
        SHA256.hash(data: Data("\(size.rawValue)|\(attachment.id)".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// The attachment's own name, made safe for one path component, with an
    /// extension from the content type when it has none.
    public static func fileName(for attachment: Attachment) -> String {
        var name = attachment.name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name.allSatisfy({ $0 == "." }) {
            name = "attachment"
        }
        name = String(name.prefix(200))
        if (name as NSString).pathExtension.isEmpty,
           let ext = extensions[attachment.contentType.lowercased()] {
            name += ".\(ext)"
        }
        return name
    }

    private static let extensions = [
        "image/png": "png", "image/jpeg": "jpg", "image/gif": "gif",
        "image/webp": "webp", "image/heic": "heic", "image/heif": "heif"
    ]

    // MARK: - Memory and disk

    private func remember(_ data: Data, _ key: String) {
        memory.setObject(data as NSData, forKey: key as NSString, cost: data.count)
    }

    private func entryDirectory(_ key: String) -> URL? {
        directory?.appending(path: key, directoryHint: .isDirectory)
    }

    private func storedFile(_ key: String) -> URL? {
        guard let entry = entryDirectory(key),
              let contents = try? FileManager.default.contentsOfDirectory(
                  at: entry,
                  includingPropertiesForKeys: nil
              )
        else { return nil }
        return contents.first
    }

    private func readFromDisk(_ key: String) -> Data? {
        guard let file = storedFile(key), let data = try? Data(contentsOf: file) else { return nil }
        // Touched, so the cap removes what has not been looked at for longest.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path())
        return data
    }

    /// Best effort: a cache that cannot write still answers from memory.
    @discardableResult
    private func writeToDisk(_ data: Data, _ key: String, name: String) -> URL? {
        guard let entry = entryDirectory(key) else { return nil }
        let file = entry.appending(path: name)
        do {
            try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } catch {
            return nil
        }
        trim(keeping: entry)
        return file
    }

    private struct Entry {
        let entry: URL
        let date: Date
        let bytes: Int
    }

    /// Removes the least recently used entries until the disk is under the cap.
    private func trim(keeping newest: URL) {
        guard let directory else { return }
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let entries = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return }
        var sized: [Entry] = entries.compactMap { entry in
            guard let file = try? manager.contentsOfDirectory(at: entry, includingPropertiesForKeys: keys)
                .first,
                let values = try? file.resourceValues(forKeys: Set(keys))
            else { return nil }
            return Entry(
                entry: entry,
                date: values.contentModificationDate ?? .distantPast,
                bytes: values.fileSize ?? 0
            )
        }
        var total = sized.reduce(0) { $0 + $1.bytes }
        sized.sort { $0.date < $1.date }
        for candidate in sized
            where total > capacity && candidate.entry.standardizedFileURL != newest.standardizedFileURL {
            try? manager.removeItem(at: candidate.entry)
            total -= candidate.bytes
        }
    }
}
