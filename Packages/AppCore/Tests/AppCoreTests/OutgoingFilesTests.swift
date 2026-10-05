import ChatKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AppCore

/// `OutgoingFiles.attachment(for:)`: a file's type, size and pixel size, read
/// from real files on disk, and `nil` for anything that is not a file.
struct OutgoingFilesTests {
    private static func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "outgoing-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A real PNG, `width` by `height`, with an EXIF orientation when given.
    private static func png(width: Int, height: Int, orientation: Int? = nil, at url: URL) throws {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try #require(context.makeImage())
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        )
        let properties = orientation.map { [kCGImagePropertyOrientation: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, image, properties)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test func anImageCarriesItsTypeSizeAndPixels() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Screen Shot 1.png")
        try Self.png(width: 40, height: 30, at: url)
        let attachment = try #require(OutgoingFiles.attachment(for: url))
        #expect(attachment.name == "Screen Shot 1.png")
        #expect(attachment.contentType == "image/png")
        #expect(try attachment.byteSize == Data(contentsOf: url).count)
        #expect(attachment.width == 40)
        #expect(attachment.height == 30)
        #expect(attachment.id == url.standardizedFileURL.path(percentEncoded: false))
    }

    /// A phone's portrait photo is stored landscape and turned by EXIF; the
    /// shape reserved must be the one the transcript will draw.
    @Test func anOrientationThatTurnsTheImageSwapsItsSides() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "portrait.png")
        try Self.png(width: 40, height: 30, orientation: 6, at: url)
        let attachment = try #require(OutgoingFiles.attachment(for: url))
        #expect(attachment.width == 30)
        #expect(attachment.height == 40)
    }

    @Test func aFileThatIsNotAPictureHasNoPixels() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "notes.txt")
        try Data("hello".utf8).write(to: url)
        let attachment = try #require(OutgoingFiles.attachment(for: url))
        #expect(attachment.contentType == "text/plain")
        #expect(attachment.byteSize == 5)
        #expect(attachment.width == nil)
    }

    @Test func anUnknownExtensionIsOctetStream() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "data.zzqx")
        try Data("x".utf8).write(to: url)
        #expect(OutgoingFiles.attachment(for: url)?.contentType == "application/octet-stream")
    }

    @Test func aFolderOrAMissingFileIsNothing() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(OutgoingFiles.attachment(for: directory) == nil)
        #expect(OutgoingFiles.attachment(for: directory.appending(path: "missing.png")) == nil)
    }
}
