import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// The link and card section prints counts only (links spec §2). Every
/// sentinel below is lowercase and readable, so a leak would show.
struct LinkCardShapesTests {
    private static let secretHost = "secret-intranet.example"
    private static let secretTitle = "confidential plan"

    private func message(
        _ text: String,
        annotations: [GChatBridgeCore.Annotation] = [],
        attachments: [GChatBridgeCore.Attachment] = [],
        creator: String = "users/other"
    ) -> GChatBridgeCore.Message {
        var message = GChatBridgeCore.Message()
        message.textBody = text
        message.annotations = annotations
        message.attachments = attachments
        message.creator.userID.id = creator
        return message
    }

    private func link(
        start: Int32?, length: Int32?,
        url: String = "https://\(secretHost)/plan",
        title: String? = secretTitle,
        image: String? = nil,
        source: UrlMetadata.UrlSource? = nil
    ) -> GChatBridgeCore.Annotation {
        var metadata = UrlMetadata()
        metadata.url.url = url
        if let title {
            metadata.title = title
        }
        if let image {
            metadata.imageURL = image
        }
        if let source {
            metadata.urlSource = source
        }
        var annotation = GChatBridgeCore.Annotation()
        annotation.type = .url
        if let start {
            annotation.startIndex = start
        }
        if let length {
            annotation.length = length
        }
        annotation.urlMetadata = metadata
        return annotation
    }

    private func shapes(_ messages: [GChatBridgeCore.Message], me: String? = nil) -> LinkCardShapes {
        var shapes = LinkCardShapes()
        APIProbeReport.countLinkCardShapes(messages, selfUserID: me, into: &shapes)
        return shapes
    }

    @Test func aSpanOverTheURLItselfIsInRangeAndIsTheURL() {
        let text = "see https://acme.example/a now"
        let counted = shapes([message(text, annotations: [link(start: 4, length: 22)])])
        #expect(counted.urlMetadata == 1)
        #expect(counted.urlAnnotationsByType == 1)
        #expect(counted.spanInRange == 1)
        #expect(counted.spanIsURL == 1)
        #expect(counted.linkMessagesWithoutURLInText == 0)
    }

    @Test func aZeroLengthLinkInTextWithNoURLIsTheNoURLCase() {
        let counted = shapes([message("Look at this", annotations: [link(start: 0, length: 0)])])
        #expect(counted.spanZero == 1)
        #expect(counted.linkMessagesWithoutURLInText == 1)
    }

    @Test func aHyperlinkedWordIsInRangeButNotAURL() {
        let counted = shapes([message(
            "read the doc", annotations: [link(start: 9, length: 3, source: .richText)]
        )])
        #expect(counted.spanInRange == 1)
        #expect(counted.spanIsURL == 0)
        #expect(counted.urlSources["4"] == 1)
        #expect(counted.linkMessagesWithoutURLInText == 1)
    }

    @Test func absentAndOutOfRangeSpansAreCountedApart() {
        let counted = shapes([message("short", annotations: [
            link(start: nil, length: nil), link(start: 2, length: 40)
        ])])
        #expect(counted.spanAbsent == 1)
        #expect(counted.spanOutOfRange == 1)
    }

    @Test func imageHostsAreClassedAndNothingIsNamed() {
        let counted = shapes([message("x", annotations: [
            link(start: 0, length: 0, image: "https://lh3.googleusercontent.com/p"),
            link(start: 0, length: 0, image: "https://cdn.\(Self.secretHost)/x.png")
        ])])
        #expect(counted.imageHosts["google"] == 1)
        #expect(counted.imageHosts["other"] == 1)
        let report = APIProbeReport.linkCardShapesLines(counted).joined(separator: "\n")
        #expect(!report.contains(Self.secretHost))
        #expect(!report.contains(Self.secretTitle))
        #expect(!report.contains("lh3"))
    }

    @Test func cardsAreCountedByWidgetAndClickKind() {
        var title = JAddOnsFormattedText()
        var element = JAddOnsFormattedText.FormattedTextElement()
        element.styledText.text = "deploy finished"
        title.formattedTextElements = [element]
        var paragraph = JAddOnsWidget()
        paragraph.textParagraph.text.originalText = "<b>shipped</b>"
        var open = JAddOnsWidget.Button()
        open.textButton.onClick.openLink.url = "https://\(Self.secretHost)/pr/1"
        var callback = JAddOnsWidget.Button()
        callback.textButton.onClick.action = JAddOnsFormAction()
        var row = JAddOnsWidget()
        row.buttons = [open, callback]
        var section = JAddOnsCardItem.CardItemSection()
        section.widgets = [paragraph, row]
        var card = JAddOnsCardItem()
        card.header.title = title
        card.sections = [section]
        var attachment = GChatBridgeCore.Attachment()
        attachment.cardAddOnData = card

        let counted = shapes([message("", attachments: [attachment])])
        #expect(counted.withAttachmentsField == 1)
        #expect(counted.cardsDecoded == 1)
        #expect(counted.cardsByteScan == 1)
        #expect(counted.cardsWithHeader == 1)
        #expect(counted.sections == 1)
        #expect(counted.widgetKinds["textParagraph"] == 1)
        #expect(counted.widgetKinds["buttons"] == 1)
        #expect(counted.clickKinds["openLink"] == 1)
        #expect(counted.clickKinds["action"] == 1)
        #expect(counted.textElements == 1)
        #expect(counted.textOriginalWithMarkup == 1)
        let report = APIProbeReport.linkCardShapesLines(counted).joined(separator: "\n")
        #expect(!report.contains(Self.secretHost))
        #expect(!report.contains("shipped"))
    }

    /// Review finding (minor 12, re-graded): a widget kind the vendored proto
    /// lacks is named by its field number, so one run says which is missing.
    @Test func anUnknownWidgetIsNamedByItsFieldNumber() throws {
        // Field 23, wire type 2 (length-delimited), empty: tag 0xBA 0x01, length 0.
        var widget = JAddOnsWidget()
        try widget.merge(serializedBytes: Data([0xBA, 0x01, 0x00]))
        var section = JAddOnsCardItem.CardItemSection()
        section.widgets = [widget]
        var card = JAddOnsCardItem()
        card.sections = [section]
        var attachment = GChatBridgeCore.Attachment()
        attachment.cardAddOnData = card
        let counted = shapes([message("", attachments: [attachment])])
        #expect(counted.widgetKinds["empty"] == 1)
        #expect(counted.unknownWidgetFields["23"] == 1)
        #expect(APIProbeReport.linkCardShapesLines(counted).joined().contains("unknown widget fields: 23×1"))
    }

    @Test func ownSendsWithAURLAreCountedWithAndWithoutAnAnnotation() {
        let counted = shapes([
            message("mine https://acme.example/a", creator: "users/me"),
            message(
                "mine https://acme.example/b", annotations: [link(start: 5, length: 22)], creator: "users/me"
            ),
            message("theirs https://acme.example/c")
        ], me: "users/me")
        #expect(counted.ownWithURL == 2)
        #expect(counted.ownWithURLAnnotated == 1)
    }
}
