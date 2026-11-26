import ChatKit
import Foundation

extension Showcase {
    static let directLines: [Line] = [
        Line(
            id: "showcase/maya-1",
            conversation: mayaDM,
            sender: maya,
            minute: 80,
            text: "Morning! Have you seen the updated Juniper direction?"
        ),
        Line(
            id: "showcase/maya-2",
            conversation: mayaDM,
            sender: alex,
            minute: 82,
            text: "Just did. That forest green is exactly what it needed."
        ),
        Line(
            id: "showcase/maya-3",
            conversation: mayaDM,
            sender: maya,
            minute: 85,
            text: "Thank you! I’ve been moving these colors around all morning 😄",
            reactions: [Reaction(emoji: "💚", count: 1, includesMe: true)]
        ),
        Line(
            id: "showcase/maya-4",
            conversation: mayaDM,
            sender: alex,
            minute: 88,
            text: "The kind of detail that makes the whole thing feel right."
        ),
        Line(
            id: "showcase/maya-5",
            conversation: mayaDM,
            sender: maya,
            minute: 91,
            text: "One last look at the board before I export it?",
            attachments: [board]
        ),
        Line(
            id: "showcase/maya-6",
            conversation: mayaDM,
            sender: alex,
            minute: 118,
            text: "All good from me. Let’s go with it! 🙌"
        ),
        Line(
            id: "showcase/maya-7",
            conversation: mayaDM,
            sender: maya,
            minute: 119,
            text: "Perfect. Coffee after the review? ☕"
        ),
        Line(
            id: "showcase/dm-noah-review",
            conversation: noahDM,
            sender: noah,
            minute: 90,
            text: "Can you give the keyboard flow a quick look? Tab order is much simpler now."
        ),
        Line(
            id: "showcase/noah-reply-1",
            conversation: noahDM,
            sender: alex,
            minute: 94,
            text: "Already tried it. Everything follows the reading order.",
            thread: "showcase/dm-noah-review"
        ),
        Line(
            id: "showcase/noah-reply-2",
            conversation: noahDM,
            sender: noah,
            minute: 98,
            text: "Great. I also added a visible focus ring to the image controls.",
            thread: "showcase/dm-noah-review"
        ),
        Line(
            id: "showcase/noah-2",
            conversation: noahDM,
            sender: alex,
            minute: 101,
            text: "The small-window layout feels good too. Nice work.",
            reactions: [Reaction(emoji: "🙏", count: 1, includesMe: false)]
        ),
        Line(
            id: "showcase/priya-1",
            conversation: priyaDM,
            sender: priya,
            minute: 35,
            text: "I trimmed the headline to ‘Small details. Better days.’ Too much?"
        ),
        Line(
            id: "showcase/priya-2",
            conversation: priyaDM,
            sender: alex,
            minute: 39,
            text: "It’s just enough. Let the artwork do the rest."
        ),
        Line(
            id: "showcase/priya-3",
            conversation: priyaDM,
            sender: priya,
            minute: 41,
            text: "Exactly what I was hoping you’d say ✨",
            edited: true
        ),
        Line(
            id: "showcase/sam-1",
            conversation: samDM,
            sender: sam,
            minute: -1450,
            text: "Found a new coffee place by the park. Excellent cinnamon buns."
        ),
        Line(
            id: "showcase/sam-2",
            conversation: samDM,
            sender: alex,
            minute: -1445,
            text: "That sounds like a very important research trip."
        ),
        Line(
            id: "showcase/sam-3",
            conversation: samDM,
            sender: sam,
            minute: -1442,
            text: "Strictly professional. Saturday at ten? 🥐"
        ),
        Line(
            id: "showcase/julia-1",
            conversation: juliaDM,
            sender: julia,
            minute: 15,
            text: "The studio review is in the calendar. I left the last ten minutes open for questions."
        ),
        Line(
            id: "showcase/julia-2",
            conversation: juliaDM,
            sender: alex,
            minute: 18,
            text: "Perfect. I’ll bring the updated brief.",
            attachments: [brief]
        ),
        Line(
            id: "showcase/bot-1",
            conversation: botDM,
            sender: bot,
            minute: 60,
            text: "Good morning, Alex. Your studio preview is ready.",
            cards: [buildCard]
        ),
        Line(
            id: "showcase/bot-2",
            conversation: botDM,
            sender: alex,
            minute: 63,
            text: "Thanks, Studio Bot!"
        ),
        Line(
            id: "showcase/bot-3",
            conversation: botDM,
            sender: bot,
            minute: 64,
            text: "One less thing on the checklist. 🌱"
        )
    ]

    static let socialLines: [Line] = [
        Line(
            id: "showcase/crew-1",
            conversation: launchCrew,
            sender: priya,
            minute: 87,
            text: "Final check-in: copy is done, design is looking lovely, and Noah has the preview."
        ),
        Line(
            id: "showcase/crew-2",
            conversation: launchCrew,
            sender: noah,
            minute: 92,
            text: "The preview is up. There’s a card with the details in Build & ship."
        ),
        Line(
            id: "showcase/crew-3",
            conversation: launchCrew,
            sender: alex,
            minute: 95,
            text: "Here’s the short checklist so nothing gets lost in the thread.",
            attachments: [checklist]
        ),
        Line(
            id: "showcase/crew-4",
            conversation: launchCrew,
            sender: maya,
            minute: 113,
            text: "@Alex Morgan artwork exports are ready for your sign-off.",
            reactions: [Reaction(emoji: "🎉", count: 3, includesMe: true)],
            mentions: [Mention(target: .user(alex), start: 0, length: 12)]
        ),
        Line(
            id: "showcase/coffee-1",
            conversation: coffee,
            sender: sam,
            minute: 6,
            text: "Serious studio question: one large coffee or two small coffees?"
        ),
        Line(
            id: "showcase/coffee-2",
            conversation: coffee,
            sender: maya,
            minute: 9,
            text: "Two small coffees. Twice as many coffee breaks."
        ),
        Line(
            id: "showcase/coffee-3",
            conversation: coffee,
            sender: alex,
            minute: 12,
            text: "The most convincing design rationale I’ve heard all week.",
            reactions: [
                Reaction(emoji: "😂", count: 5, includesMe: false),
                Reaction(emoji: "☕", count: 3, includesMe: true)
            ]
        ),
        Line(
            id: "showcase/weekend-1",
            conversation: weekend,
            sender: sam,
            minute: 45,
            text: "Made a very unofficial poster for Saturday.",
            attachments: [poster]
        ),
        Line(
            id: "showcase/weekend-2",
            conversation: weekend,
            sender: julia,
            minute: 49,
            text: "‘Absolutely no agenda’ is my favorite kind of agenda.",
            reactions: [Reaction(emoji: "💯", count: 2, includesMe: true)]
        ),
        Line(
            id: "showcase/weekend-removed",
            conversation: weekend,
            sender: alex,
            minute: 50,
            text: "",
            deleted: true
        ),
        Line(
            id: "showcase/weekend-3",
            conversation: weekend,
            sender: alex,
            minute: 53,
            text: "Count me in. I’ll bring an extra flask of coffee."
        )
    ]
}

public extension FixtureScript {
    /// Seeds read markers and briefly demonstrates typing without appending an endless transcript.
    static let showcaseDemo = FixtureScript(steps: [
        .receipts(ReadReceiptUpdate(
            conversationID: Showcase.mayaDM,
            enabled: true,
            positions: [.init(
                member: Showcase.maya,
                readThrough: Showcase.at(118)
            )]
        )),
        .receipts(ReadReceiptUpdate(conversationID: Showcase.design, enabled: true, positions: [
            .init(member: Showcase.maya, readThrough: Showcase.at(120)),
            .init(member: Showcase.noah, readThrough: Showcase.at(120)),
            .init(member: Showcase.priya, readThrough: Showcase.at(110))
        ])),
        .delay(.seconds(12)),
        .scopedTyping(TypingUpdate(conversationID: Showcase.mayaDM, member: Showcase.maya, isTyping: true)),
        .delay(.seconds(4)),
        .scopedTyping(TypingUpdate(conversationID: Showcase.mayaDM, member: Showcase.maya, isTyping: false))
    ])
}
