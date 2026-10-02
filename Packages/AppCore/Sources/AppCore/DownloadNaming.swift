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

    /// Moves `staged` into `folder` as `leaf`, or `leaf 2`, `leaf 3`…, taking
    /// the first name the move succeeds at, so two downloads finishing
    /// together cannot both claim one name.
    public static func place(_ staged: URL, as leaf: String, in folder: URL) throws -> URL {
        let base = (leaf as NSString).deletingPathExtension
        let ext = (leaf as NSString).pathExtension
        for number in 1 ... 9999 {
            let name = number == 1 ? leaf : ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            let candidate = folder.appendingPathComponent(name)
            do {
                try FileManager.default.moveItem(at: staged, to: candidate)
                return candidate
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// Puts `source` at `target`, which the person chose and, if it exists,
    /// agreed to replace. The replacement is made beside `target` first, so
    /// a copy or move that fails leaves whatever was there untouched; and
    /// `target` being `source` itself changes nothing.
    static func deliver(_ source: URL, to target: URL, copying: Bool) throws {
        if isSameFile(source, target) {
            return
        }
        let manager = FileManager.default
        let sibling = target.deletingLastPathComponent()
            .appendingPathComponent(".kibble-\(UUID().uuidString)")
        do {
            if copying {
                try manager.copyItem(at: source, to: sibling)
            } else {
                try manager.moveItem(at: source, to: sibling)
            }
            if manager.fileExists(atPath: target.path(percentEncoded: false)) {
                _ = try manager.replaceItemAt(target, withItemAt: sibling)
            } else {
                try manager.moveItem(at: sibling, to: target)
            }
        } catch {
            try? manager.removeItem(at: sibling)
            throw error
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
