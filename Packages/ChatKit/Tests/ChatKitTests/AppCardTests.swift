import Foundation
import Testing
@testable import ChatKit

struct AppCardTests {
    private static let deploy = AppCard(
        header: AppCard.Header(
            title: RichText("Deploy finished"), subtitle: RichText("storefront-web #412"),
            imageURL: URL(string: "https://acme.example/bot.png"), circularImage: true
        ),
        sections: [
            AppCard.Section(header: RichText("Summary"), widgets: [
                .text(RichText(runs: [
                    RichText.Run(text: "Shipped ", bold: true),
                    RichText.Run(text: "in 4 minutes. "),
                    RichText.Run(text: "Logs", link: URL(string: "https://acme.example/logs/412"))
                ])),
                .decorated(AppCard.Decorated(
                    top: RichText("Environment"), content: RichText("production"),
                    iconURL: URL(string: "https://acme.example/icon.png"),
                    button: LinkButton(label: "Open", url: URL(string: "https://acme.example/env")!)
                )),
                .image(AppCard.Picture(
                    url: URL(string: "https://acme.example/graph.png")!,
                    aspectRatio: 1.5
                )),
                .divider,
                .buttons([LinkButton(
                    label: "Open PR",
                    url: URL(string: "https://code.acme.example/pr/412")!
                )])
            ])
        ]
    )

    @Test func aMessageWithACardMatchesItsGoldenFile() throws {
        try expectWireStable(Message(
            id: Fixture.messageID, conversationID: Fixture.spaceID, threadID: Fixture.threadID,
            sender: Fixture.botID, text: "", createdAt: Fixture.createdAt, cards: [Self.deploy]
        ), golden: "message-cards")
    }

    @Test func anUnknownWidgetDecodesAndReEncodesVerbatim() throws {
        let json = #"{"count":3,"type":"carousel"}"#
        let decoded = try Wire.decode(AppCard.Widget.self, from: json)
        guard case let .unknown(type, _) = decoded else {
            Issue.record("expected .unknown")
            return
        }
        #expect(type == "carousel")
        #expect(try Wire.json(decoded) == json)
    }

    @Test func aRunWritesOnlyTheFlagsItSets() throws {
        #expect(try Wire.json(RichText.Run(text: "hi")) == #"{"text":"hi"}"#)
        #expect(try Wire.json(RichText.Run(text: "hi", italic: true)) == #"{"italic":true,"text":"hi"}"#)
    }

    @Test func aHeaderWithoutTheImageStyleReadsAsSquare() throws {
        let header = try Wire.decode(AppCard.Header.self, from: #"{"title":{"runs":[{"text":"x"}]}}"#)
        #expect(!header.circularImage)
    }

    @Test func noCardsOmitsTheKeyAndAnEmptyCardIsEmpty() throws {
        let plain = Message(
            id: Fixture.messageID, conversationID: Fixture.spaceID, threadID: Fixture.threadID,
            sender: Fixture.botID, text: "x", createdAt: Fixture.createdAt
        )
        #expect(try !(Wire.json(plain)).contains("cards"))
        #expect(AppCard().isEmpty)
        #expect(!Self.deploy.isEmpty)
        #expect(RichText(runs: [RichText.Run(text: "a"), RichText.Run(text: "b")]).plainText == "ab")
    }
}
