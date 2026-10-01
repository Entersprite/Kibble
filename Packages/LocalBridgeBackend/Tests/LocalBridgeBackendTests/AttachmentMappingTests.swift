import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// `UPLOAD_METADATA` annotations becoming `ChatKit.Attachment`s
/// (`ChannelEventMapping.attachments(_:)`).
///
/// The fixture's shape is the one live traffic was measured to carry
/// (`findings.md` §51.1): annotation type 13, the `upload_metadata` oneof,
/// a token, a name, a MIME type and field 5's dimensions. The values are
/// invented.
struct AttachmentMappingTests {
    private static func upload(
        token: String = "upload-token",
        name: String? = "screenshot.png",
        contentType: String? = "image/png",
        dimensions: (Int32, Int32)? = (416, 340)
    ) -> GChatBridgeCore.Annotation {
        var metadata = UploadMetadata()
        metadata.attachmentToken = token
        if let name {
            metadata.contentName = name
        }
        if let contentType {
            metadata.contentType = contentType
        }
        if let (width, height) = dimensions {
            var dimension = Dimension()
            dimension.width = width
            dimension.height = height
            metadata.originalDimension = dimension
        }
        var annotation = GChatBridgeCore.Annotation()
        annotation.type = .uploadMetadata
        annotation.uploadMetadata = metadata
        return annotation
    }

    @Test func anUploadBecomesAnAttachmentWithItsTokenNameTypeAndSize() {
        #expect(ChannelEventMapping.attachments([Self.upload()]) == [ChatKit.Attachment(
            id: "upload-token",
            name: "screenshot.png",
            contentType: "image/png",
            width: 416,
            height: 340
        )])
    }

    /// The URLs need credentials, so a view could never load them; the token
    /// is handed back to `attachmentData(_:size:)` instead.
    @Test func noURLIsInvented() throws {
        let attachment = try #require(ChannelEventMapping.attachments([Self.upload()]).first)
        #expect(attachment.downloadURL == nil)
        #expect(attachment.thumbnailURL == nil)
    }

    @Test func anUploadWithNoTokenIsSkippedBecauseNothingCouldFetchIt() {
        #expect(ChannelEventMapping.attachments([Self.upload(token: "")]).isEmpty)
    }

    @Test func absentDimensionsAreUnknownNotZero() throws {
        let attachment = try #require(ChannelEventMapping.attachments([Self.upload(dimensions: nil)]).first)
        #expect(attachment.width == nil)
        #expect(attachment.height == nil)
    }

    @Test func aZeroDimensionIsUnknownToo() throws {
        let attachment = try #require(ChannelEventMapping.attachments([Self.upload(dimensions: (0, 340))])
            .first)
        #expect(attachment.width == nil)
        #expect(attachment.height == nil)
    }

    @Test func absentNameAndTypeAreEmptyStrings() throws {
        let attachment = try #require(
            ChannelEventMapping.attachments([Self.upload(name: nil, contentType: nil)]).first
        )
        #expect(attachment.name.isEmpty)
        #expect(attachment.contentType.isEmpty)
    }

    @Test func otherAnnotationsAreNotAttachments() {
        let mention = MentionFixture.mention(.mention, user: "u-2", start: 0, length: 5)
        #expect(ChannelEventMapping.attachments([mention]).isEmpty)
    }

    @Test func uploadsKeepTheirOrder() {
        let mapped = ChannelEventMapping.attachments([
            Self.upload(token: "first"), Self.upload(token: "second")
        ])
        #expect(mapped.map(\.id) == ["first", "second"])
    }

    /// The channel and the history call share `domainMessage(_:)`, so this
    /// covers both paths.
    @Test func aMessageCarriesItsAttachments() throws {
        let message = MentionFixture.reply(text: "", annotations: [Self.upload()])
        let mapped = try #require(ChannelEventMapping.domainMessage(message))
        #expect(mapped.attachments.map(\.id) == ["upload-token"])
        #expect(mapped.text.isEmpty)
    }
}
