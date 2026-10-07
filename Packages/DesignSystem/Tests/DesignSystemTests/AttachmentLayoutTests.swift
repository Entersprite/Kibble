import ChatKit
import CoreGraphics
import Foundation
import Testing
@testable import DesignSystem

/// How a message's attachments are laid out: which draw as pictures, which as
/// file chips, whether the text bubble draws at all, and how big a picture is
/// before its bytes arrive.
struct AttachmentLayoutTests {
    private func message(text: String, attachments: [ChatKit.Attachment]) -> Message {
        Message(
            id: Message.ID("m"), conversationID: Conversation.ID("dm:1"), threadID: MessageThread.ID("t"),
            sender: Member.ID("users/alice"), text: text,
            createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            attachments: attachments
        )
    }

    private let png = ChatKit.Attachment(
        id: "a",
        name: "a.png",
        contentType: "image/png",
        width: 416,
        height: 340
    )
    private let pdf = ChatKit.Attachment(id: "b", name: "b.pdf", contentType: "application/pdf")

    // MARK: - Parts

    @Test func anImageOnlyMessageDrawsNoTextBubble() {
        let parts = AttachmentLayout.parts(of: message(text: "", attachments: [png]), canLoadImages: true)
        #expect(parts.images == [png])
        #expect(parts.files.isEmpty)
        #expect(!parts.showsText)
    }

    /// Whitespace is not text: a bubble around nothing is the thing avoided.
    @Test func whitespaceBesideAnImageIsNotText() {
        #expect(!AttachmentLayout.parts(of: message(text: " \n", attachments: [png]), canLoadImages: true)
            .showsText)
    }

    @Test func textBesideAnImageDrawsBoth() {
        let parts = AttachmentLayout.parts(of: message(text: "look", attachments: [png]), canLoadImages: true)
        #expect(parts.images == [png])
        #expect(parts.showsText)
    }

    @Test func aFileIsAChipNotAPicture() {
        let parts = AttachmentLayout.parts(
            of: message(text: "", attachments: [png, pdf]),
            canLoadImages: true
        )
        #expect(parts.images == [png])
        #expect(parts.files == [pdf])
    }

    /// No loader means nothing could ever fill a picture, so it is named
    /// instead (`CLAUDE.md`: never draw a control the seam cannot honour).
    @Test func withoutALoaderAnImageIsAChip() {
        let parts = AttachmentLayout.parts(of: message(text: "", attachments: [png]), canLoadImages: false)
        #expect(parts.images.isEmpty)
        #expect(parts.files == [png])
    }

    /// An image type nothing here can decode would fail forever behind a
    /// Retry that can never succeed, so it is named instead.
    @Test(arguments: ["image/svg+xml", "image/x-icon", "image/vnd.adobe.photoshop"])
    func anUndecodableImageTypeIsAChip(_ contentType: String) {
        let odd = ChatKit.Attachment(id: "o", name: "o", contentType: contentType)
        let parts = AttachmentLayout.parts(of: message(text: "", attachments: [odd]), canLoadImages: true)
        #expect(parts.images.isEmpty)
        #expect(parts.files == [odd])
    }

    @Test(arguments: ["image/png", "image/jpeg", "IMAGE/GIF", "image/webp", "image/heic", "image/heif"])
    func aDecodableImageTypeIsAPicture(_ contentType: String) {
        let picture = ChatKit.Attachment(id: "p", name: "p", contentType: contentType)
        let parts = AttachmentLayout.parts(of: message(text: "", attachments: [picture]), canLoadImages: true)
        #expect(parts.images == [picture])
    }

    /// The case every message before this slice is.
    @Test func aMessageWithNoAttachmentsAlwaysShowsItsText() {
        let parts = AttachmentLayout.parts(of: message(text: "", attachments: []), canLoadImages: true)
        #expect(parts.showsText)
    }

    // MARK: - Size before the bytes arrive

    @Test func aLandscapeImageFitsTheMaximumWidth() {
        #expect(AttachmentLayout.displaySize(width: 1600, height: 1000) == CGSize(width: 320, height: 200))
    }

    @Test func aPortraitImageFitsTheMaximumHeight() {
        #expect(AttachmentLayout.displaySize(width: 1000, height: 1600) == CGSize(width: 200, height: 320))
    }

    /// One point per pixel at most, so a small image is not blown up blurry.
    @Test func aSmallImageIsNotEnlarged() {
        #expect(AttachmentLayout.displaySize(width: 120, height: 80) == CGSize(width: 120, height: 80))
    }

    @Test func aSliverIsKeptBigEnoughToClick() {
        let size = AttachmentLayout.displaySize(width: 4000, height: 20)
        #expect(size.width == 320)
        #expect(size.height == 40)
    }

    @Test(arguments: [
        (Int?.none, Int?.some(100)),
        (.some(100), .none),
        (.some(0), .some(100)),
        (.none, .none)
    ])
    func anUnknownSizeIsTheSquareFallback(width: Int?, height: Int?) {
        #expect(AttachmentLayout.displaySize(width: width, height: height) == CGSize(width: 200, height: 200))
    }

    @Test func aFileWithNoNameIsStillCalledSomething() {
        let unnamed = ChatKit.Attachment(id: "c", name: "", contentType: "application/zip")
        #expect(AttachmentLayout.label(for: unnamed) == "Attachment")
        #expect(AttachmentLayout.label(for: pdf) == "b.pdf")
    }

    // MARK: - Link and app cards (links spec §7.3, §7.5)

    private static func linked(text: String, links: [MessageLink] = [], cards: [AppCard] = []) -> Message {
        Message(
            id: Message.ID("m"), conversationID: Conversation.ID("space/s"), threadID: MessageThread.ID("t"),
            sender: Member.ID("u"), text: text, createdAt: Date(timeIntervalSince1970: 0), links: links,
            cards: cards
        )
    }

    private static let specs = URL(string: "https://acme.example/specs")!
    private static let preview = LinkPreview(title: "Specs")

    @Test func aPreviewOnlyMessageHasNoEmptyBubble() {
        let parts = AttachmentLayout.parts(
            of: Self.linked(text: " ", links: [MessageLink(url: Self.specs, preview: Self.preview)]),
            canLoadImages: true
        )
        #expect(!parts.showsText)
        #expect(parts.previews.count == 1)
    }

    /// Review Focus 1: an unanchored link with no title still gets a card,
    /// and the message still gets no empty bubble.
    @Test func anUnanchoredLinkWithoutAPreviewStillGetsACard() throws {
        let gif = try MessageLink(url: #require(URL(string: "https://media.acme.example/party.gif")))
        let parts = AttachmentLayout.parts(of: Self.linked(text: "", links: [gif]), canLoadImages: true)
        #expect(parts.previews == [gif])
        #expect(!parts.showsText)
    }

    @Test func anAnchoredLinkWithoutAPreviewIsOnlyAnInlineLink() {
        let parts = AttachmentLayout.parts(
            of: Self.linked(text: "read the doc", links: [MessageLink(url: Self.specs, start: 9, length: 3)]),
            canLoadImages: true
        )
        #expect(parts.previews.isEmpty)
        #expect(parts.showsText)
    }

    @Test func oneCardPerURL() {
        let links = [
            MessageLink(url: Self.specs, start: 0, length: 5, preview: Self.preview),
            MessageLink(url: Self.specs, start: 9, length: 5, preview: Self.preview)
        ]
        let parts = AttachmentLayout.parts(
            of: Self.linked(text: "specs or specs", links: links),
            canLoadImages: true
        )
        #expect(parts.previews.count == 1)
    }

    @Test func aCardOnlyMessageHasNoEmptyBubbleAndAnEmptyCardIsStillDrawn() {
        let parts = AttachmentLayout.parts(of: Self.linked(text: "", cards: [AppCard()]), canLoadImages: true)
        #expect(!parts.showsText)
        #expect(parts.cards == [AppCard()])
    }
}
