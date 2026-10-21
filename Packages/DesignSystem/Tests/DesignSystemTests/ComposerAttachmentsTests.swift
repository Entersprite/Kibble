#if os(macOS)
    import AppKit
    import Testing
    @testable import DesignSystem

    /// A staged file that is not a picture gets Quick Look's thumbnail (a
    /// document's first page, or the file's icon) instead of a generic
    /// symbol. Through the real thumbnail service, which runs headless.
    struct ComposerAttachmentsTests {
        @Test func aDocumentGetsAQuickLookThumbnail() async throws {
            let file = FileManager.default.temporaryDirectory
                .appending(path: "composer-thumbnail-\(UUID().uuidString).txt")
            try Data("Quarterly notes\nLine two".utf8).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }

            let image = await ComposerAttachmentChip.quickLookThumbnail(of: file, side: 36, scale: 2)

            let thumbnail = try #require(image)
            #expect(max(thumbnail.width, thumbnail.height) <= 72)
            #expect(max(thumbnail.width, thumbnail.height) > 0)
        }
    }
#endif
