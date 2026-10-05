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
            id: url.standardizedFileURL.path(percentEncoded: false),
            file: url,
            name: url.lastPathComponent,
            contentType: mime,
            byteSize: size,
            width: pixels?.width,
            height: pixels?.height
        )
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
