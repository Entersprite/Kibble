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

    /// A custom emoji's picture, by its reference (reactions spec §3).
    public typealias CustomEmojiFetch = @Sendable (CustomEmojiRef) async throws -> Data

    /// `originalFile(for:)` without a directory: there is nowhere to put a file.
    public struct NoDirectory: Error {}

    /// Any call on an instance after `erase()`.
    public struct Erased: Error {}

    /// The original could not be written where Quick Look could open it.
    public struct WriteFailed: Error {}

    /// `customEmojiData(for:)` on a cache built without a way to fetch one.
    public struct NoCustomEmojiFetch: Error {}

    private let directory: URL?
    private let capacity: Int
    private let customEmojiFetch: CustomEmojiFetch?
    private let fetch: Fetch
    private let memory = NSCache<NSString, NSData>()
    private var inFlight: [String: Task<Data, any Error>] = [:]

    /// Set by `erase()`, and never cleared: the instance belonged to the
    /// account just signed out of. Checked on entry and again after every
    /// `await`, because a call already queued on the actor can run after the
    /// erase, and a fetch already in flight finishes after it.
    private var isErased = false

    /// `capacity` bounds the disk, in bytes; the oldest entries go first. One
    /// entry larger than the whole cap is kept anyway, because the file it
    /// just wrote may be the one Quick Look is about to open.
    /// `customEmojiFetch` is optional so a cache that only holds attachments
    /// needs nothing new.
    public init(
        directory: URL?,
        capacity: Int = 200 * 1_048_576,
        customEmojiFetch: CustomEmojiFetch? = nil,
        fetch: @escaping Fetch
    ) {
        self.directory = directory
        self.capacity = capacity
        self.customEmojiFetch = customEmojiFetch
        self.fetch = fetch
        memory.totalCostLimit = 64 * 1_048_576
    }

    public func data(for attachment: Attachment, size: AttachmentSize) async throws -> Data {
        try await cached(Self.key(attachment, size), name: Self.fileName(for: attachment)) { [fetch] in
            try await fetch(attachment, size)
        }
    }

    /// A custom emoji's picture, under the same custody as an attachment:
    /// memory, then disk, then one fetch shared by every capsule asking, and
    /// gone on `erase()`. Keyed by the emoji's id, never its token, so a
    /// token refreshed by a later history load still finds the stored image.
    /// The in-flight key is the id *and* the token: a tokenless capsule and a
    /// tokened one for the same emoji must not share one fetch, or the
    /// tokenless request's "no image token" throw would answer for both.
    public func customEmojiData(for emoji: CustomEmojiRef) async throws -> Data {
        guard let customEmojiFetch else { throw NoCustomEmojiFetch() }
        return try await cached(
            Self.key(emoji), name: "custom-emoji",
            flight: "\(Self.key(emoji))|\(emoji.imageToken ?? "")"
        ) {
            try await customEmojiFetch(emoji)
        }
    }

    /// Memory and disk are keyed by `key` alone, so a tokenless request still
    /// finds an image another request already stored. In flight is keyed by
    /// `flight` instead (defaulting to `key`), so a request that must not be
    /// folded into another one in flight for the same `key` - a tokenless
    /// custom emoji request beside a tokened one, say - gets its own fetch.
    /// Checked for an erase on entry and again after the `await`.
    private func cached(
        _ key: String,
        name: String,
        flight: String? = nil,
        fetch: @escaping @Sendable () async throws -> Data
    ) async throws -> Data {
        guard !isErased else { throw Erased() }
        if let hit = memory.object(forKey: key as NSString) {
            return hit as Data
        }
        if let stored = readFromDisk(key) {
            remember(stored, key)
            return stored
        }
        let flightKey = flight ?? key
        if let running = inFlight[flightKey] {
            return try await running.value
        }
        let task = Task { try await fetch() }
        inFlight[flightKey] = task
        defer { inFlight[flightKey] = nil }
        let data = try await task.value
        guard !isErased else { throw Erased() }
        remember(data, key)
        writeToDisk(data, key, name: name)
        return data
    }

    /// Keeps bytes this app already has - a picture it has just sent - under
    /// both sizes, so the transcript does not fetch back what it uploaded.
    /// The preview's server rendition is smaller, and the view decodes either
    /// at bubble size, so the original serves for both.
    public func seed(_ data: Data, for attachment: Attachment) {
        guard !isErased else { return }
        for size in [AttachmentSize.preview, .original] {
            let key = Self.key(attachment, size)
            remember(data, key)
            writeToDisk(data, key, name: Self.fileName(for: attachment))
        }
    }

    /// The full-size image as a file, for Quick Look.
    public func originalFile(for attachment: Attachment) async throws -> URL {
        guard !isErased else { throw Erased() }
        guard directory != nil else { throw NoDirectory() }
        let key = Self.key(attachment, .original)
        // No second erase check here: `data(for:)` throws `Erased` after its
        // own `await`, and nothing between there and the write below suspends.
        let data = try await data(for: attachment, size: .original)
        if let existing = storedFile(key) {
            return existing
        }
        // Memory had it but the disk did not, or the write failed: try once
        // more, and report the failure this time.
        guard let written = writeToDisk(data, key, name: Self.fileName(for: attachment)) else {
            throw WriteFailed()
        }
        return written
    }

    /// Everything, from memory and disk; every fetch still running is
    /// disowned, and every later call on this instance throws `Erased`.
    public func erase() {
        isErased = true
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
        digest("\(size.rawValue)|\(attachment.id)")
    }

    /// `emoji|` cannot collide with an attachment's key, whose prefix is a
    /// size's raw value.
    static func key(_ emoji: CustomEmojiRef) -> String {
        digest("emoji|\(emoji.id)")
    }

    private static func digest(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8))
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
        if (name as NSString).pathExtension.isEmpty,
           let ext = extensions[attachment.contentType.lowercased()] {
            name += ".\(ext)"
        }
        return truncated(name, toBytes: 200)
    }

    /// Cut from the end of the stem by whole Characters until the UTF-8 form
    /// fits, keeping the extension Quick Look types the file by. The limit is
    /// a file name's 255 bytes, with room to spare; 200 CJK characters are
    /// 600 of them.
    private static func truncated(_ name: String, toBytes limit: Int) -> String {
        guard name.utf8.count > limit else { return name }
        let ext = (name as NSString).pathExtension
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        var stem = Substring((name as NSString).deletingPathExtension)
        while !stem.isEmpty, stem.utf8.count + suffix.utf8.count > limit {
            stem = stem.dropLast()
        }
        return String(stem) + suffix
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
        // Through the URL, never `file.path()`: that is percent-encoded, so a
        // name with a space - every macOS screenshot - was silently skipped.
        var touched = file
        var values = URLResourceValues()
        values.contentModificationDate = Date()
        try? touched.setResourceValues(values)
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
