import Foundation

/// Keeps each staged file readable for exactly as long as something may read
/// it.
///
/// A file chosen in the file importer arrives as a security-scoped URL, which
/// a sandboxed app may read only between `startAccessingSecurityScopedResource()`
/// and `stopAccessingSecurityScopedResource()`. The read that matters, the
/// upload, comes after Send, long after the importer has closed; the chip's
/// thumbnail and Quick Look read it meanwhile. So access starts when a file is
/// staged and stops once no composer has it staged and no read of it is in
/// flight: it was sent, removed, refused, or the session ended. Holding it for
/// the rest of the launch instead would leak a kernel resource per file, which
/// the sandbox caps. A file dropped or pasted is held the same way, at no cost
/// when its URL is not scoped (`startAccessing` answers `false`).
///
/// A picture pasted as data is written to a folder this app owns, and the
/// folder is deleted at the same moment instead.
///
/// One per session, so a read finishing after sign-out ends nothing in the
/// next one. The effects are injected so a test can count them.
@MainActor
final class StagedFileCustody {
    /// What ends each held file's custody, by `OutgoingFiles.id(for:)`.
    private var held: [String: () -> Void] = [:]
    /// Reads in flight outside staging, by id.
    private var reading: [String: Int] = [:]
    /// The staged ids last reported, for a read that ends after them.
    private var staged: Set<String> = []

    private let startAccess: (URL) -> Bool
    private let stopAccess: (URL) -> Void
    private let removeItem: (URL) -> Void

    init(
        startAccess: @escaping (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
        stopAccess: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() },
        removeItem: @escaping (URL) -> Void = { try? FileManager.default.removeItem(at: $0) }
    ) {
        self.startAccess = startAccess
        self.stopAccess = stopAccess
        self.removeItem = removeItem
    }

    /// Starts access to `url` for the file staged as `id`, once however often
    /// it is staged: one start, one stop.
    func access(_ url: URL, id: String) {
        guard held[id] == nil, startAccess(url) else { return }
        held[id] = { [stopAccess] in stopAccess(url) }
    }

    /// Takes a folder this app wrote a file into, to delete when the file
    /// `id` is released.
    func own(_ folder: URL, id: String) {
        held[id]?()
        held[id] = { [removeItem] in removeItem(folder) }
    }

    /// A read outside staging, such as keeping a sent picture's bytes, which
    /// holds the file past its unstaging until `endRead`.
    func beginRead(_ id: String) {
        reading[id, default: 0] += 1
    }

    func endRead(_ id: String) {
        guard let count = reading[id] else { return }
        reading[id] = count > 1 ? count - 1 : nil
        release(keeping: staged)
    }

    /// Ends custody of every file not in `staged` and not being read.
    func release(keeping staged: Set<String>) {
        self.staged = staged
        for (id, end) in held where !staged.contains(id) && reading[id] == nil {
            held[id] = nil
            end()
        }
    }

    /// The session is ending: everything goes, reads in flight included,
    /// because the uploads reading them are cancelled with it.
    func releaseAll() {
        let ends = held.values
        held = [:]
        reading = [:]
        staged = []
        for end in ends {
            end()
        }
    }

    /// The ids in custody, for a test.
    var heldIDs: Set<String> {
        Set(held.keys)
    }

    private static var sweptLeftovers = false

    /// Deletes what an earlier run left in `directory` when it quit without
    /// ending its sessions, as a crash does, once per process and before
    /// its first pasted picture is written: nothing of this process's can
    /// be there yet, so no session loses a file it holds.
    static func sweepLeftovers(in directory: URL) {
        guard !sweptLeftovers else { return }
        sweptLeftovers = true
        try? FileManager.default.removeItem(at: directory)
    }
}
