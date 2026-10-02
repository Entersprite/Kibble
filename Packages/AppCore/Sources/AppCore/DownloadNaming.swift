import Foundation

/// Where a downloaded file lands: one safe leaf name, and the first free
/// spelling of it in the folder, the way Finder numbers a copy. Nothing is
/// ever overwritten.
public enum DownloadNaming {
    /// The attachment's name reduced to one leaf: no path separators, no
    /// control characters, no leading dots or spaces. "Attachment" if nothing
    /// is left.
    public static func leaf(_ name: String) -> String {
        let scalars = name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let flat = String(String.UnicodeScalarView(scalars))
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let trimmed = String(flat.drop { $0 == "." || $0 == " " }).trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Attachment" : trimmed
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
}
