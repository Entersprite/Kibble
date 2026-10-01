import Foundation
import GChatBridgeCore
import SwiftProtobuf
import Testing
@testable import LocalBridgeBackend

/// The probe's two attachment sections: what `list_topics` carries in the way
/// of uploads, and what one real fetch's redirect chain looks like. Both
/// render counts, MIME types, hosts and statuses only - never a token, a
/// filename, a URL or a byte of the attachment.
///
/// Fixtures are built from the vendored proto's field numbers, not from a
/// capture: no capture of an upload exists yet, which is why this probe does.
struct AttachmentProbeTests {
    private typealias Fixture = MentionFixture

    /// Lowercase, so no masking rule could be what keeps it out of a report.
    private static let tokenSecret = "lowercasetokensecret"
    private static let nameSecret = "holiday-photo-of-someone.jpg"

    private static func upload(
        token: String = tokenSecret,
        contentType: String = "image/png",
        name: String? = nameSecret,
        dimensions: (Int32, Int32)? = (640, 480)
    ) throws -> GChatBridgeCore.Annotation {
        var metadata = UploadMetadata()
        metadata.attachmentToken = token
        metadata.contentType = contentType
        if let name {
            metadata.contentName = name
        }
        if let (width, height) = dimensions {
            // Field 5 (`original_dimension`) is commented out of the vendored
            // proto, so a real response leaves it in `unknownFields`. Appended
            // as bytes and decoded back, which is how a response gets it there.
            let dimension = Data([0x08]) + varint(UInt64(width)) + Data([0x10]) + varint(UInt64(height))
            let field = Data([0x2A]) + varint(UInt64(dimension.count)) + dimension
            let known: Data = try metadata.serializedBytes()
            metadata = try UploadMetadata(serializedBytes: known + field)
        }
        var annotation = GChatBridgeCore.Annotation()
        annotation.type = .uploadMetadata
        annotation.uploadMetadata = metadata
        return annotation
    }

    private static func varint(_ value: UInt64) -> Data {
        var value = value
        var bytes = Data()
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 {
                byte |= 0x80
            }
            bytes.append(byte)
        } while value != 0
        return bytes
    }

    // MARK: - Shapes

    @Test("uploads are counted per message, with MIME types, token lengths and field numbers")
    func countsUploads() throws {
        let shapes = try APIProbeReport.attachmentShapes([
            Fixture.reply(
                text: "",
                annotations: [Self.upload(), Self.upload(contentType: "application/pdf")]
            ),
            Fixture.reply(text: "plain"),
            Fixture.reply(text: "", annotations: [Self.upload(name: nil, dimensions: nil)])
        ])
        #expect(shapes.messages == 3)
        #expect(shapes.withUploads == 2)
        #expect(shapes.uploads == 3)
        #expect(shapes.contentTypes == ["image/png": 2, "application/pdf": 1])
        #expect(shapes.tokenLengths == [Self.tokenSecret.utf8.count: 3])
        #expect(shapes.namesPresent == 2)
        #expect(shapes.metadataFields[5] == 2)
        #expect(shapes.metadataFields[1] == 3)
        #expect(shapes.dimensions == Array(
            repeating: UploadDimensionShape(width: 640, height: 480),
            count: 2
        ))
    }

    @Test("the first image upload is the one chosen to fetch")
    func choosesFirstImage() throws {
        let shapes = try APIProbeReport.attachmentShapes([
            Fixture.reply(annotations: [Self.upload(token: "pdf", contentType: "application/pdf")]),
            Fixture.reply(annotations: [Self.upload(token: "img", contentType: "image/jpeg")])
        ])
        #expect(shapes.firstImage == ProbedUpload(token: "img", contentType: "image/jpeg"))
    }

    @Test("the shapes report carries no token and no filename")
    func shapesNeverLeak() throws {
        let lines = try APIProbeReport.attachmentShapesLines(
            APIProbeReport.attachmentShapes([Fixture.reply(annotations: [Self.upload()])])
        ).joined(separator: "\n")
        #expect(!lines.contains(Self.tokenSecret))
        #expect(!lines.contains("holiday"))
        #expect(lines.contains("image/png×1"))
        #expect(lines.contains("upload metadata fields: 1×1 3×1 4×1 5×1"))
        #expect(lines.contains("dimensions: 640×480"))
    }

    @Test("a MIME type that is not shaped like one is printed as a length")
    func oddContentTypeIsMasked() throws {
        let lines = try APIProbeReport.attachmentShapesLines(
            APIProbeReport
                .attachmentShapes([Fixture
                        .reply(annotations: [Self.upload(contentType: Self.nameSecret)])])
        ).joined(separator: "\n")
        #expect(!lines.contains("holiday"))
        #expect(lines.contains("(unusual, \(Self.nameSecret.count) chars)×1"))
    }

    // MARK: - The fetch report

    @Test("a successful fetch reports its hops, the type, the size and the format")
    func successLines() {
        let fetched = FetchedAttachment(
            body: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A]),
            contentType: "image/png",
            hops: [
                AttachmentHop(host: "chat.google.com", status: 302, carriedCredentials: true),
                AttachmentHop(host: "lh3.googleusercontent.com", status: 200, carriedCredentials: false)
            ]
        )
        let lines = APIProbeReport.attachmentFetchLines(label: "/u/0", outcome: .success(fetched))
        #expect(lines == [
            "  /u/0: chat.google.com 302 (credentials) → lh3.googleusercontent.com 200",
            "    content type image/png, 6 bytes, format PNG"
        ])
    }

    @Test("a failed fetch reports the hops it made and the reason")
    func failureLines() {
        let failure = AttachmentFetchFailure(
            reason: .httpStatus(403),
            hops: [AttachmentHop(host: "chat.google.com", status: 403, carriedCredentials: true)]
        )
        let lines = APIProbeReport.attachmentFetchLines(label: "no account", outcome: .failure(failure))
        #expect(lines == [
            "  no account: chat.google.com 403 (credentials)",
            "    FAILED: HTTP 403"
        ])
    }

    @Test("a host outside the known set is reduced to its last two labels")
    func unknownHostsAreReduced() {
        let fetched = FetchedAttachment(
            body: Data(),
            contentType: nil,
            hops: [AttachmentHop(
                host: "doc-0s-abc123-docs.googleusercontent.com", status: 200, carriedCredentials: false
            )]
        )
        let lines = APIProbeReport.attachmentFetchLines(label: "x", outcome: .success(fetched))
        #expect(lines.first == "  x: googleusercontent.com (+1 label) 200")
        #expect(lines.last == "    content type none, 0 bytes, format unrecognised")
    }

    @Test("formats are read from magic bytes")
    func magic() {
        #expect(APIProbeReport.imageFormat(Data([0xFF, 0xD8, 0xFF, 0xE0])) == "JPEG")
        #expect(APIProbeReport.imageFormat(Data("GIF89a".utf8)) == "GIF")
        #expect(APIProbeReport.imageFormat(Data("RIFF\0\0\0\0WEBPVP8 ".utf8)) == "WebP")
        #expect(APIProbeReport.imageFormat(Data("\0\0\0\u{18}ftypheic".utf8)) == "HEIF")
        #expect(APIProbeReport.imageFormat(Data("<html>".utf8)) == "unrecognised")
    }
}
