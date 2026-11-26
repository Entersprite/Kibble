import ChatKit
import Foundation

extension Showcase {
    static let meetingConversations: [Conversation] = [
        meeting(standupPrevious, title: "Studio standup", series: "showcase/standup-series", minute: -1440),
        meeting(standup, title: "Studio standup", series: "showcase/standup-series", minute: 30),
        meeting(critique, title: "Design critique", series: "showcase/critique-series", minute: 60),
        Conversation(
            id: oneOff,
            kind: .meetChat,
            title: "Coffee with the studio",
            members: [alex, maya, sam, julia],
            memberCount: 4
        )
    ]

    private static func meeting(
        _ id: Conversation.ID, title: String, series: String, minute: Int
    ) -> Conversation {
        Conversation(
            id: id, kind: .meetChat, title: title, members: [alex, maya, noah, priya, julia], memberCount: 5,
            meeting: MeetingOccurrence(
                seriesID: .init(series),
                occurrenceID: id.rawValue,
                seriesTitle: title,
                scheduledStart: at(minute)
            )
        )
    }

    static let meetingLines: [Line] = [
        Line(
            id: "showcase/previous-1",
            conversation: standupPrevious,
            sender: julia,
            minute: -1440,
            text: "Today: autumn palette, the preview build, and the launch checklist."
        ),
        Line(
            id: "showcase/previous-2",
            conversation: standupPrevious,
            sender: alex,
            minute: -1434,
            text: "Let’s keep the first direction and make the typography a little quieter."
        ),
        Line(
            id: "showcase/previous-3",
            conversation: standupPrevious,
            sender: maya,
            minute: -1429,
            text: "I’ll bring a new board to tomorrow’s review."
        ),
        Line(
            id: "showcase/standup-1",
            conversation: standup,
            sender: julia,
            minute: 30,
            text: "Morning, everyone! Same agenda, fresh coffee."
        ),
        Line(
            id: "showcase/standup-2",
            conversation: standup,
            sender: maya,
            minute: 33,
            text: "The new direction is in Design studio. Much happier with this palette."
        ),
        Line(
            id: "showcase/standup-3",
            conversation: standup,
            sender: noah,
            minute: 38,
            text: "Preview is ready. I’ll finish the small-window checks this morning."
        ),
        Line(
            id: "showcase/critique-1",
            conversation: critique,
            sender: maya,
            minute: 61,
            text: "Leaving the board here so we can keep the review in one place.",
            attachments: [board]
        ),
        Line(
            id: "showcase/critique-2",
            conversation: critique,
            sender: priya,
            minute: 68,
            text: "The copy and the artwork finally feel like they belong together."
        ),
        Line(
            id: "showcase/one-off-1",
            conversation: oneOff,
            sender: sam,
            minute: 72,
            text: "A quick hello to the new faces. No slides required."
        ),
        Line(
            id: "showcase/one-off-2",
            conversation: oneOff,
            sender: julia,
            minute: 74,
            text: "Best meeting invitation of the week. ☕"
        )
    ]

    /// Older conversations give directories, search and sidebar scrolling useful content too.
    struct ExtraSpace {
        let slug: String
        let title: String
        let text: String
    }

    static let extraSpaces: [ExtraSpace] = [
        ExtraSpace(
            slug: "inspiration",
            title: "Inspiration",
            text: "A place for small discoveries and ideas worth keeping."
        ),
        ExtraSpace(
            slug: "accessibility",
            title: "Accessibility",
            text: "The keyboard review is complete. Every action has a visible focus state."
        ),
        ExtraSpace(
            slug: "photography",
            title: "Photography",
            text: "Soft morning light works best for the next collection."
        ),
        ExtraSpace(
            slug: "copy",
            title: "Words & stories",
            text: "Shorter sentences. More room for the reader."
        ),
        ExtraSpace(
            slug: "garden",
            title: "The studio garden",
            text: "The windowsill plants have survived another week. 🌱"
        ),
        ExtraSpace(
            slug: "research",
            title: "Customer research",
            text: "People found the simpler navigation much easier to follow."
        ),
        ExtraSpace(
            slug: "planning",
            title: "Next season",
            text: "A notebook full of ideas, and plenty of time to explore them."
        ),
        ExtraSpace(
            slug: "welcome",
            title: "New around here",
            text: "Welcome! Introduce yourself and tell us your favorite coffee order."
        )
    ]

    static let extraConversations: [Conversation] = extraSpaces.enumerated().map { index, row in
        Conversation(
            id: .init("showcase/space-\(row.slug)"),
            kind: .space,
            title: row.title,
            hasUnread: index == 0,
            members: [alex, maya, noah, priya, sam],
            memberCount: 5,
            repliesEnabled: true
        )
    }

    static let extraLines: [Line] = extraSpaces.enumerated().flatMap { index, row in
        [
            Line(
                id: "showcase/\(row.slug)-1",
                conversation: .init("showcase/space-\(row.slug)"),
                sender: maya,
                minute: -180 - index * 10,
                text: row.text
            ),
            Line(
                id: "showcase/\(row.slug)-2",
                conversation: .init("showcase/space-\(row.slug)"),
                sender: alex,
                minute: -179 - index * 10,
                text: "Thanks for sharing. Let’s keep the ideas here."
            )
        ]
    }
}
