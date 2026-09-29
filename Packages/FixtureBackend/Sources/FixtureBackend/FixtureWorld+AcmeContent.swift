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

        var message: Message {
            Message(
                id: Message.ID(id),
                conversationID: conversation,
                threadID: MessageThread.ID(thread),
                sender: sender,
                text: text,
                createdAt: at(minute),
                reactions: reactions,
                mentions: mentions
            )
        }
    }

    static func allMessages() -> [Message] {
        ((priceEngineLines + otherSpaceLines + directLines).map(\.message)
            + filler.map(\.message))
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// The threaded space, including one topic with four replies - the shape a
    /// flat conversation cannot produce and the thread panel exists to render.
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
            minute: 22
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
            minute: 34
        ),
        Line(
            id: "msg:pe-5", conversation: priceEngine, thread: "topic:variance", sender: dan,
            text: "Confirmed - the new MAP file is in the feed. Want me to auto-approve those?",
            minute: 36
        ),
        Line(
            id: "msg:pe-6", conversation: priceEngine, thread: "topic:variance", sender: maya,
            text: "Yes, auto-approve anything matching the MAP file and leave the rest "
                + "for review.",
            minute: 40
        ),
        Line(
            id: "msg:pe-mention", conversation: priceEngine, thread: "topic:variance", sender: maya,
            text: "@Alex Carter can you sign off on the approval rule before standup?",
            minute: 44,
            mentions: [Mention(target: .user(alex), start: 0, length: 12)]
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
            minute: -19
        ),
        Line(
            id: "msg:sw-2", conversation: storefront, thread: "topic:checkout", sender: tom,
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
            id: "msg:sw-3", conversation: storefront, thread: "topic:rollout", sender: priya,
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
            id: "msg:fd-2", conversation: catalog, thread: "topic:import", sender: alex,
            text: "Any conflicts with the existing entries? Those were messy last time.",
            minute: -1420
        ),
        Line(
            id: "msg:st-1", conversation: standup, thread: "topic:meet-standup", sender: maya,
            text: "Starting in 3 - the variance list is on screen when you join.",
            minute: 57
        ),
        Line(
            id: "msg:st-2", conversation: standup, thread: "topic:meet-standup", sender: dan,
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
            id: "msg:lt-2", conversation: launchTeam, thread: "topic:launch", sender: priya,
            text: "Copy drafts land today. Dan, can you own the redirect table?",
            minute: 64
        ),
        Line(
            id: "msg:lt-3", conversation: launchTeam, thread: "topic:launch", sender: dan,
            text: "On it. Redirects done by end of day.",
            minute: 66
        ),
        Line(
            id: "msg:md-1", conversation: mayaDM, thread: "topic:dm-maya", sender: maya,
            text: "Can you review the variance list before standup?",
            minute: 55
        ),
        Line(
            id: "msg:dd-1", conversation: danDM, thread: "topic:dm-dan", sender: alex,
            text: "Feed parser fix looks good, shipped it.",
            minute: -1400
        ),
        Line(
            id: "msg:dd-2", conversation: danDM, thread: "topic:dm-dan", sender: dan,
            text: "Thanks - I will close out the incident doc today.",
            minute: -1390
        )
    ]
}

// MARK: - The demo script

public extension FixtureScript {
    /// What the demo world does while you watch it.
    ///
    /// Paced for a human: `FixtureDemoDriver` honours these delays, while a
    /// test playing the same script sees every event instantly. Every
    /// identifier here is checked against `FixtureWorld.acme` by a test,
    /// because a script naming a missing person throws mid-demo.
    static let acmeDemo = FixtureScript(steps: [
        .delay(.seconds(4)),
        .typing(conversation: Acme.mayaDM, member: Acme.maya, isTyping: true),
        .delay(.seconds(3)),
        .typing(conversation: Acme.mayaDM, member: Acme.maya, isTyping: false),
        .incomingMessage(
            conversation: Acme.mayaDM,
            from: Acme.maya,
            text: "Also - the approval rule is ready to ship whenever you are.",
            thread: MessageThread.ID("topic:dm-maya")
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
    ])
}
