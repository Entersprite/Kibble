import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// App cards (links spec §4.2). Shapes from the proto and purple's renderer;
/// `findings.md` §60's measured shapes are `[Verify]` until the probe runs.
struct CardMappingTests {
    private func text(_ plain: String) -> JAddOnsFormattedText {
        var element = JAddOnsFormattedText.FormattedTextElement()
        element.styledText.text = plain
        var text = JAddOnsFormattedText()
        text.formattedTextElements = [element]
        return text
    }

    private func button(_ label: String, open url: String? = nil, link: String? = nil, callback: Bool = false)
        -> JAddOnsWidget.Button {
        var textButton = JAddOnsWidget.TextButton()
        textButton.text = text(label)
        if let url {
            textButton.onClick.openLink.url = url
        }
        if let link {
            textButton.onClick.link = link
        }
        if callback {
            textButton.onClick.action = JAddOnsFormAction()
        }
        var button = JAddOnsWidget.Button()
        button.textButton = textButton
        return button
    }

    private func card(_ widgets: [JAddOnsWidget], title: String? = "Deploy finished") -> JAddOnsCardItem {
        var section = JAddOnsCardItem.CardItemSection()
        section.widgets = widgets
        var card = JAddOnsCardItem()
        if let title {
            card.header.title = text(title)
        }
        card.sections = [section]
        return card
    }

    @Test func aHeaderTextAndALinkButtonMap() throws {
        var paragraph = JAddOnsWidget()
        paragraph.textParagraph.text = text("Shipped to production in 4 minutes.")
        var row = JAddOnsWidget()
        row.buttons = [button("Open PR", open: "https://code.acme.example/pr/412")]
        var wire = card([paragraph, row])
        wire.header.subtitle = text("catalog-import #412")
        #expect(try CardMapping.card(wire) == AppCard(
            header: AppCard.Header(
                title: RichText("Deploy finished"),
                subtitle: RichText("catalog-import #412")
            ),
            sections: [AppCard.Section(widgets: [
                .text(RichText("Shipped to production in 4 minutes.")),
                .buttons([LinkButton(
                    label: "Open PR",
                    url: #require(URL(string: "https://code.acme.example/pr/412"))
                )])
            ])]
        ))
    }

    /// Review Focus 3: a callback and a dangerous scheme are never drawn.
    @Test func onlyButtonsThatOpenAWebOrMailURLSurvive() throws {
        var row = JAddOnsWidget()
        row.buttons = [
            button("Approve", callback: true),
            button("Run", link: "javascript:alert(1)"),
            button("Mail", link: "mailto:ops@acme.example"),
            button("Open", open: "https://acme.example")
        ]
        #expect(try CardMapping.widgets(row) == [.buttons([
            LinkButton(label: "Mail", url: #require(URL(string: "mailto:ops@acme.example"))),
            LinkButton(label: "Open", url: #require(URL(string: "https://acme.example")))
        ])])
        var callbacksOnly = JAddOnsWidget()
        callbacksOnly.buttons = [button("Approve", callback: true)]
        #expect(CardMapping.widgets(callbacksOnly).isEmpty)
    }

    @Test func decoratedRowsMapFromAllThreeWireKinds() throws {
        var keyValue = JAddOnsWidget()
        keyValue.keyValue.topLabel = text("Environment")
        keyValue.keyValue.content = text("production")
        keyValue.keyValue.iconURL = "https://acme.example/i.png"
        keyValue.keyValue.button = button("Open", open: "https://acme.example/env")
        var pair = JAddOnsWidget()
        pair.textKeyValue.key = text("Owner")
        pair.textKeyValue.text = text("Platform")
        pair.textKeyValue.onClick.link = "https://acme.example/team"
        var imagePair = JAddOnsWidget()
        imagePair.imageKeyValue.iconURL = "https://acme.example/i.png"
        imagePair.imageKeyValue.text = text("Healthy")
        #expect(try CardMapping.widgets(keyValue) == [.decorated(AppCard.Decorated(
            top: RichText("Environment"), content: RichText("production"),
            iconURL: URL(string: "https://acme.example/i.png"),
            button: LinkButton(label: "Open", url: #require(URL(string: "https://acme.example/env")))
        ))])
        #expect(CardMapping.widgets(pair) == [.decorated(AppCard.Decorated(
            top: RichText("Owner"), content: RichText("Platform"),
            link: URL(string: "https://acme.example/team")
        ))])
        #expect(CardMapping.widgets(imagePair) == [.decorated(AppCard.Decorated(
            content: RichText("Healthy"), iconURL: URL(string: "https://acme.example/i.png")
        ))])
    }

    @Test func imagesNeedHTTPSAndDividersMap() throws {
        var image = JAddOnsWidget()
        image.image.fifeImageURL = "https://acme.example/graph.png"
        image.image.aspectRatio = 1.5
        var insecure = JAddOnsWidget()
        insecure.image.fifeImageURL = "http://acme.example/graph.png"
        var divider = JAddOnsWidget()
        divider.divider = JAddOnsWidget.Divider()
        #expect(try CardMapping.widgets(image) == [.image(AppCard.Picture(
            url: #require(URL(string: "https://acme.example/graph.png")), aspectRatio: 1.5
        ))])
        #expect(CardMapping.widgets(insecure).isEmpty)
        #expect(CardMapping.widgets(divider) == [.divider])
    }

    /// Review finding (minor 5, re-graded): a non-finite ratio would make the
    /// store's JSON encoder throw and fail the whole history page it came in.
    @Test(arguments: [Double.infinity, -Double.infinity, Double.nan, 0, -1])
    func aRatioThatIsNotAPositiveFiniteNumberIsDropped(_ ratio: Double) throws {
        var image = JAddOnsWidget()
        image.image.fifeImageURL = "https://acme.example/graph.png"
        image.image.aspectRatio = ratio
        #expect(try CardMapping
            .widgets(image) ==
            [.image(AppCard.Picture(url: #require(URL(string: "https://acme.example/graph.png"))))])
    }

    @Test func formInputsAreNotMappedAndAnUnmappableCardIsEmpty() {
        var field = JAddOnsWidget()
        field.textField.name = "reason"
        #expect(CardMapping.widgets(field).isEmpty)
        #expect(CardMapping.card(card([field], title: nil)).isEmpty)
    }

    @Test func onlyCardAttachmentsBecomeCards() {
        var cardAttachment = GChatBridgeCore.Attachment()
        cardAttachment.cardAddOnData = card([])
        let plain = GChatBridgeCore.Attachment()
        #expect(CardMapping.cards([plain, cardAttachment]).count == 1)
    }
}
