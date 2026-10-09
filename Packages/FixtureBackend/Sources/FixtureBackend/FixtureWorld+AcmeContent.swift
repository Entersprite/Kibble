import ChatKit
import Foundation

// MARK: - The demo world's messages

extension Acme {
    /// One line of invented conversation.
    ///
    /// A row type rather than six arguments to a factory: swiftlint caps
    /// parameter counts, and a table reads like the transcript it is meant to
    /// be.
    struct Line {
        let id: String
        let conversation: Conversation.ID
        let thread: String
        let sender: Member.ID
        let text: String

        /// Minutes from `Acme.start`. Negative is earlier - yesterday's
        /// traffic, so the sidebar has something to sort.
        let minute: Int

        var reactions: [Reaction] = []
        var mentions: [Mention] = []
        var attachments: [Attachment] = []
        var links: [MessageLink] = []
        var cards: [AppCard] = []

        /// A reply in `thread`, which an earlier line started. Said here,
        /// never worked out from the ids (threads spec §1).
        var isReply = false

        var message: Message {
            Message(
                id: Message.ID(id),
                conversationID: conversation,
                threadID: MessageThread.ID(thread),
                sender: sender,
                text: text,
                createdAt: at(minute),
                reactions: reactions,
                attachments: attachments,
                mentions: mentions,
                links: links,
                cards: cards,
                isReply: isReply
            )
        }
    }

    static func allMessages() -> [Message] {
        ((priceEngineLines + otherSpaceLines + directLines + trimLines).map(\.message)
            + filler.map(\.message))
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// The threaded space: `topic:sync` with one reply and `topic:variance`
    /// with four - the shape a flat conversation cannot produce and the
    /// thread panel exists to render. Everywhere in this world a topic is
    /// named after its first message and only replies share it, as on the
    /// wire (`findings.md` §63.3).
    static let priceEngineLines: [Line] = [
        Line(
            id: "msg:pe-1", conversation: priceEngine, thread: "topic:sync", sender: maya,
            text: "Morning - the overnight sync finished. 41k SKUs updated, 312 flagged "
                + "for price variance over 15%.",
            minute: 14
        ),
        Line(
            id: "msg:pe-2", conversation: priceEngine, thread: "topic:sync", sender: dan,
            text: "Nice. Are the flagged ones mostly the winter promo overlap again?",
            minute: 22,
            isReply: true
        ),
        Line(
            id: "msg:pe-3", conversation: priceEngine, thread: "topic:variance", sender: maya,
            text: "Mostly, yes - 280 of the 312. The rest look like genuine distributor "
                + "price changes.",
            minute: 31,
            reactions: [Reaction(emoji: "👍", count: 2, includesMe: false)]
        ),
        Line(
            id: "msg:pe-4", conversation: priceEngine, thread: "topic:variance", sender: priya,
            text: "The distributor ones are probably the MAP update from Tuesday.",
            minute: 34,
            isReply: true
        ),
        Line(
            id: "msg:pe-5", conversation: priceEngine, thread: "topic:variance", sender: dan,
            text: "Confirmed - the new MAP file is in the feed. Want me to auto-approve those?",
            minute: 36,
            isReply: true
        ),
        Line(
            id: "msg:pe-6", conversation: priceEngine, thread: "topic:variance", sender: maya,
            text: "Yes, auto-approve anything matching the MAP file and leave the rest "
                + "for review.",
            minute: 40,
            attachments: [Attachment(
                id: "fixture-upload:map-file", name: "MAP update - Tuesday.pdf",
                contentType: "application/pdf"
            )],
            isReply: true
        ),
        Line(
            id: "msg:pe-mention", conversation: priceEngine, thread: "topic:variance", sender: maya,
            text: "@Alex Carter can you sign off on the approval rule before standup?",
            minute: 44,
            mentions: [Mention(target: .user(alex), start: 0, length: 12)],
            isReply: true
        ),
        Line(
            id: "msg:pe-7", conversation: priceEngine, thread: "topic:standup", sender: alex,
            text: "Sounds right. Let us review the remaining 32 in standup and ship the "
                + "approval rule after.",
            minute: 48
        )
    ]

    static let otherSpaceLines: [Line] = [
        Line(
            id: "msg:sw-1", conversation: storefront, thread: "topic:checkout", sender: priya,
            text: "Checkout A/B results are in: the single-page flow converted 2.3% "
                + "better on mobile.",
            minute: -19,
            attachments: [Attachment(
                id: "fixture-upload:funnel", name: "checkout-funnel.png",
                contentType: "image/png", width: 320, height: 200
            )]
        ),
        Line(
            id: "msg:sw-2", conversation: storefront, thread: "topic:sw-2", sender: tom,
            text: "That tracks with the session recordings - people were abandoning at "
                + "the shipping step.",
            minute: -5
        ),
        Line(
            id: "msg:sw-all", conversation: storefront, thread: "topic:rollout", sender: priya,
            text: "@all the single-page checkout ships Thursday - shout now if anything blocks it.",
            minute: 0,
            mentions: [Mention(target: .all, start: 0, length: 4)]
        ),
        Line(
            id: "msg:sw-3", conversation: storefront, thread: "topic:sw-3", sender: priya,
            text: "Proposing we roll it to 100% on Thursday. Objections before I write it up?",
            minute: 2
        ),
        Line(
            id: "msg:fd-1", conversation: catalog, thread: "topic:import", sender: tom,
            text: "2026 model-year import is done. 214 new vehicles, 18 needed manual "
                + "trim mapping.",
            minute: -1440
        ),
        Line(
            id: "msg:fd-2", conversation: catalog, thread: "topic:fd-2", sender: alex,
            text: "Any conflicts with the existing entries? Those were messy last time.",
            minute: -1420
        ),
        Line(
            id: "msg:fd-3", conversation: catalog, thread: "topic:fd-3", sender: alex,
            text: "Spring catalog specs: https://acme.example/specs/spring",
            minute: -1400,
            links: [MessageLink(
                url: URL(string: "https://acme.example/specs/spring")!, start: 22, length: 33,
                preview: LinkPreview(
                    title: "Spring catalog specs", snippet: "Every size, one sheet.",
                    imageURL: URL(string: "https://media.acme.example/specs.png"),
                    imageWidth: 320, imageHeight: 200, domain: "acme.example"
                )
            )]
        ),
        Line(
            id: "msg:fd-4", conversation: catalog, thread: "topic:fd-4", sender: tom,
            text: "The import runbook is in the wiki.",
            minute: -1398,
            links: [MessageLink(
                url: URL(string: "https://wiki.acme.example/import-runbook")!,
                start: 11,
                length: 7
            )]
        ),
        Line(
            id: "msg:fd-5", conversation: catalog, thread: "topic:fd-5", sender: alex,
            text: "For whoever finishes the trim mapping:",
            minute: -1396,
            links: [MessageLink(
                url: URL(string: "https://media.acme.example/party.gif")!,
                preview: LinkPreview(
                    title: "Party parrot", imageURL: URL(string: "https://media.acme.example/party.png"),
                    imageWidth: 320, imageHeight: 200, domain: "media.acme.example"
                )
            )]
        ),
        Line(
            id: "msg:fd-6", conversation: catalog, thread: "topic:fd-6", sender: deployBot,
            text: "",
            minute: -1390,
            cards: [deployCard]
        ),
        Line(
            id: "msg:st-1", conversation: standup, thread: "topic:meet-standup", sender: maya,
            text: "Starting in 3 - the variance list is on screen when you join.",
            minute: 57
        ),
        Line(
            id: "msg:st-2", conversation: standup, thread: "topic:st-2", sender: dan,
            text: "Joining a minute late, wrapping up a deploy.",
            minute: 59
        )
    ]

    static let directLines: [Line] = [
        Line(
            id: "msg:lt-1", conversation: launchTeam, thread: "topic:launch", sender: maya,
            text: "Launch checklist is at 80% - the remaining items are all storefront copy.",
            minute: 58
        ),
        Line(
            id: "msg:lt-2", conversation: launchTeam, thread: "topic:lt-2", sender: priya,
            text: "Copy drafts land today. Dan, can you own the redirect table?",
            minute: 64
        ),
        Line(
            id: "msg:lt-3", conversation: launchTeam, thread: "topic:lt-3", sender: dan,
            text: "On it. Redirects done by end of day.",
            minute: 66
        ),
        Line(
            id: "msg:md-1", conversation: mayaDM, thread: "topic:dm-maya", sender: maya,
            text: "Can you review the variance list before standup?",
            minute: 55
        ),
        // A DM thread: Alex's message, Dan's reply, Alex's reply.
        Line(
            id: "msg:dd-1", conversation: danDM, thread: "topic:dm-dan", sender: alex,
            text: "Feed parser fix looks good, shipped it.",
            minute: -1400
        ),
        Line(
            id: "msg:dd-2", conversation: danDM, thread: "topic:dm-dan", sender: dan,
            text: "Thanks - I will close out the incident doc today.",
            minute: -1390,
            isReply: true
        ),
        Line(
            id: "msg:dd-3", conversation: danDM, thread: "topic:dm-dan", sender: alex,
            text: "Ping me if the doc needs a timeline.",
            minute: -1385,
            isReply: true
        )
    ]
}

// MARK: - The demo script

public extension FixtureScript {
    /// What the demo world does while you watch it, ending with replies
    /// arriving in followed threads (`acmeReplyArrives`).
    ///
    /// Paced for a human: `FixtureDemoDriver` honors these delays, while a
    /// test playing the same script sees every event instantly. Every
    /// identifier here is checked against `FixtureWorld.acme` by a test,
    /// because a script naming a missing person throws mid-demo.
    static let acmeDemo = FixtureScript(steps: acmeDemoSteps + acmeReplyArrives.steps)

    /// Maya's DM is a new topic (`thread: nil`), so it makes the DM unread,
    /// which is what her typing leads into. Priya's message is a reply in
    /// `topic:variance`.
    private static let acmeDemoSteps: [FixtureStep] = [
        .delay(.seconds(4)),
        .typing(conversation: Acme.mayaDM, member: Acme.maya, isTyping: true),
        .delay(.seconds(3)),
        .typing(conversation: Acme.mayaDM, member: Acme.maya, isTyping: false),
        .incomingMessage(
            conversation: Acme.mayaDM,
            from: Acme.maya,
            text: "Also - the approval rule is ready to ship whenever you are.",
            thread: nil
        ),
        .delay(.seconds(6)),
        .reaction(messageID: Message.ID("msg:pe-7"), emoji: "🎉", by: Acme.dan, add: true),
        .delay(.seconds(5)),
        .incomingMessage(
            conversation: Acme.priceEngine,
            from: Acme.priya,
            text: "Variance list is down to 12 after the MAP match.",
            thread: MessageThread.ID("topic:variance")
        ),
        .delay(.seconds(8)),
        .presence(member: Acme.priya, presence: .active),
        .delay(.seconds(10))
    ]
}

// MARK: - The demo world's app card

extension Acme {
    /// What a deploy app posts (links spec §7.6): a header, bold text with a
    /// link, a decorated row and a link button. Only what `AppCard` can hold:
    /// a button that calls back into the app never reaches it.
    static let deployCard = AppCard(
        header: AppCard.Header(
            title: RichText("Deploy finished"), subtitle: RichText("catalog-import #412"),
            imageURL: URL(string: "https://media.acme.example/deploy.png"), circularImage: true
        ),
        sections: [AppCard.Section(widgets: [
            .text(RichText(runs: [
                RichText.Run(text: "Shipped", bold: true),
                RichText.Run(text: " to production in 4 minutes. "),
                RichText.Run(text: "Logs", link: URL(string: "https://deploy.acme.example/logs/412"))
            ])),
            .decorated(AppCard.Decorated(
                top: RichText("Environment"), content: RichText("production"),
                link: URL(string: "https://deploy.acme.example/env/production")
            )),
            .buttons([LinkButton(
                label: "Open PR",
                url: URL(string: "https://code.acme.example/catalog/pull/412")!
            )])
        ])]
    )
}
