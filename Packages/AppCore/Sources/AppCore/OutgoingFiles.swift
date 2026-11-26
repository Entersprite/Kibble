import ChatKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What the host knows about a file the person chose to send: its type from
/// its extension, its size, and a picture's pixel size. Pure inspection of
/// one file; nothing is read beyond an image's header.
///
/// Here rather than in `SyncEngine` because it reads the file system and
/// image headers, which is the host's business, and both frameworks exist on
/// iOS, so a future iOS app shares it.
public enum OutgoingFiles {
    /// `nil` for a folder, a package, or a file that cannot be read. Its
    /// `id` is the file's path, so the same file staged twice is staged once.
    public static func attachment(for url: URL) -> OutgoingAttachment? {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentTypeKey, .isReadableKey]
        guard url.isFileURL,
              let values = try? url.resourceValues(forKeys: keys),
              values.isRegularFile == true, values.isReadable != false,
              let size = values.fileSize
        else { return nil }
        let type = values.contentType ?? UTType(filenameExtension: url.pathExtension)
        let mime = type?.preferredMIMEType ?? "application/octet-stream"
        let pixels = type?.conforms(to: .image) == true ? pixelSize(of: url) : nil
        return OutgoingAttachment(
            id: id(for: url),
            file: url,
            name: url.lastPathComponent,
            contentType: mime,
            byteSize: size,
            width: pixels?.width,
            height: pixels?.height
        )
    }

    /// The id a file stages under: its standardized path.
    public static func id(for url: URL) -> String {
        url.standardizedFileURL.path(percentEncoded: false)
    }

    /// A pasted picture's file name, the way macOS names a screenshot:
    /// "Pasted Image 2026-10-21 at 14.03.22.png", in the Mac's time zone.
    /// The time keeps two pastes apart in the conversation; the dots, not
    /// colons, keep it a valid name everywhere it is saved.
    static func pastedImageName(at date: Date, type: UTType, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let suffix = type.preferredFilenameExtension.map { ".\($0)" } ?? ""
        return "Pasted Image \(formatter.string(from: date))\(suffix)"
    }

    /// From the header alone, turned for an EXIF orientation that swaps the
    /// sides (5-8), so a portrait photo from a phone reserves a portrait
    /// shape, the way the transcript's decode will draw it.
    static func pixelSize(of url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return (5 ... 8).contains(orientation) ? (height, width) : (width, height)
    }
}
