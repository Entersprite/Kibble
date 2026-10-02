import Foundation

/// Where a downloaded file lands: one safe leaf name, and the first free
/// spelling of it in the folder, the way Finder numbers a copy. Nothing is
/// ever overwritten.
public enum DownloadNaming {
    /// The longest leaf, in UTF-8 bytes: a file system's 255 less room for
    /// the " 9999" `place` may append.
    static let maximumLeafBytes = 240

    /// The attachment's name reduced to one leaf: no path separators, no
    /// control characters, no leading dots or spaces, at most
    /// `maximumLeafBytes`. "Attachment" if nothing is left.
    public static func leaf(_ name: String) -> String {
        let scalars = name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let flat = String(String.UnicodeScalarView(scalars))
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let trimmed = String(flat.drop { $0 == "." || $0 == " " }).trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Attachment" : capped(trimmed)
    }

    /// Cuts the base and keeps the extension; an extension that alone does not
    /// fit is cut with the rest, as if the name had none.
    private static func capped(_ leaf: String) -> String {
        guard leaf.utf8.count > maximumLeafBytes else { return leaf }
        let ext = (leaf as NSString).pathExtension
        let suffix = ext.isEmpty ? "" : "." + ext
        let head = prefix(
            of: (leaf as NSString).deletingPathExtension,
            bytes: maximumLeafBytes - suffix.utf8.count
        )
        // An empty head would leave a leaf that starts with its dot.
        return head.isEmpty ? prefix(of: leaf, bytes: maximumLeafBytes) : head + suffix
    }

    /// The longest run of whole characters from the start of `text` that fits
    /// in `bytes` of UTF-8.
    private static func prefix(of text: String, bytes: Int) -> String {
        var result = ""
        var used = 0
        for character in text {
            used += character.utf8.count
            guard used <= bytes else { break }
            result.append(character)
        }
        return result
    }

    /// One move from a file to a name. A seam so a test can stand in for
    /// the one failure a single volume cannot produce: a move across volumes
    /// is a copy, and a copy can stop part-way.
    typealias Move = @Sendable (URL, URL) throws -> Void

    static let fileSystemMove: Move = { try FileManager.default.moveItem(at: $0, to: $1) }

    /// Moves `staged` into `folder` as `leaf`, or `leaf 2`, `leaf 3`…, taking
    /// the first name the move succeeds at, so two downloads finishing
    /// together cannot both claim one name.
    public static func place(_ staged: URL, as leaf: String, in folder: URL) throws -> URL {
        try place(staged, as: leaf, in: folder, moving: fileSystemMove)
    }

    static func place(_ staged: URL, as leaf: String, in folder: URL, moving move: Move) throws -> URL {
        let base = (leaf as NSString).deletingPathExtension
        let ext = (leaf as NSString).pathExtension
        for number in 1 ... 9999 {
            let name = number == 1 ? leaf : ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            let candidate = folder.appendingPathComponent(name)
            // Taken: whatever holds the name is someone's file, and stays.
            guard !exists(candidate) else { continue }
            do {
                try move(staged, candidate)
                return candidate
            } catch {
                // Taken since the look: the move refused it, and it stays too.
                if isFileExists(error) {
                    continue
                }
                // The name was free, so anything there now is this move's
                // own part-copy.
                removeIfPresent(candidate)
                throw error
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// Puts `source` at `target`, which the person chose and, if it exists,
    /// agreed to replace. The replacement is built in the system's
    /// item-replacement directory - never in `target`'s folder, which the
    /// save panel does not open to the sandbox - so a copy or move that fails
    /// leaves whatever was there untouched; and `target` being `source`
    /// itself changes nothing.
    static func deliver(
        _ source: URL,
        to target: URL,
        copying: Bool,
        moving move: Move = fileSystemMove
    ) throws {
        if isSameFile(source, target) {
            return
        }
        let manager = FileManager.default
        let scratch = replacementDirectory(for: target)
        defer { try? manager.removeItem(at: scratch) }
        let replacement = scratch.appendingPathComponent(target.lastPathComponent)
        if copying {
            try manager.copyItem(at: source, to: replacement)
        } else {
            try move(source, replacement)
        }
        if exists(target) {
            _ = try manager.replaceItemAt(target, withItemAt: replacement)
            return
        }
        do {
            try move(replacement, target)
        } catch {
            // Only a name that was free is cleared: one that has since been
            // taken holds someone else's file.
            if !isFileExists(error) {
                removeIfPresent(target)
            }
            throw error
        }
    }

    /// A fresh directory on `target`'s volume, so the replace is a rename;
    /// the app's own temporary directory when the system offers none.
    static func replacementDirectory(for target: URL) -> URL {
        let manager = FileManager.default
        if let directory = try? manager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: target,
            create: true
        ) {
            return directory
        }
        let fallback = manager.temporaryDirectory
            .appendingPathComponent("kibble-replace-\(UUID().uuidString)", isDirectory: true)
        try? manager.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    private static func isFileExists(_ error: any Error) -> Bool {
        (error as? CocoaError)?.code == .fileWriteFileExists
    }

    private static func exists(_ file: URL) -> Bool {
        FileManager.default.fileExists(atPath: file.path(percentEncoded: false))
    }

    private static func removeIfPresent(_ file: URL) {
        if exists(file) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// The file system's identity when both can be read, the resolved path
    /// otherwise.
    static func isSameFile(_ first: URL, _ second: URL) -> Bool {
        let key: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        if let left = try? first.resourceValues(forKeys: key).fileResourceIdentifier,
           let right = try? second.resourceValues(forKeys: key).fileResourceIdentifier {
            return left.isEqual(right)
        }
        return first.resolvingSymlinksInPath().standardizedFileURL
            == second.resolvingSymlinksInPath().standardizedFileURL
    }
}
