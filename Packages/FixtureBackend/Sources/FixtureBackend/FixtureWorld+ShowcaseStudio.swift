import ChatKit
import Foundation

extension Showcase {
    static let board = Attachment(
        id: "showcase/studio-board", name: "Juniper — brand direction.png", contentType: "image/png",
        byteSize: (try? ShowcaseMedia.data(named: "studio-board.png"))?.count, width: 1200, height: 720
    )
    static let brief = Attachment(
        id: "showcase/creative-brief", name: "Autumn launch — creative brief.pdf",
        contentType: "application/pdf",
        byteSize: (try? ShowcaseMedia.data(named: "creative-brief.pdf"))?.count
    )
    static let checklist = Attachment(
        id: "showcase/launch-checklist", name: "Launch checklist.txt", contentType: "text/plain",
        byteSize: (try? ShowcaseMedia.data(named: "launch-checklist.txt"))?.count
    )
    static let poster = Attachment(
        id: "showcase/weekend-poster", name: "Weekend club.png", contentType: "image/png",
        byteSize: (try? ShowcaseMedia.data(named: "weekend-poster.png"))?.count, width: 1000, height: 680
    )

    static let studioLines: [Line] = [
        Line(
            id: "showcase/design-hello",
            conversation: design,
            sender: maya,
            minute: 70,
            text: "A fresh direction for Juniper. Softer colors, a little more breathing room. 🌿"
        ),
        Line(
            id: "showcase/board",
            conversation: design,
            sender: maya,
            minute: 90,
            text: "Here’s the autumn direction. What do you think?",
            reactions: [
                Reaction(emoji: "💚", count: 4, includesMe: true),
                Reaction(emoji: "✨", count: 3, includesMe: false)
            ],
            attachments: [board]
        ),
        Line(
            id: "showcase/board-reply-1",
            conversation: design,
            sender: priya,
            minute: 94,
            text: "The warm paper background is lovely. It makes the green feel much calmer.",
            thread: "showcase/board"
        ),
        Line(
            id: "showcase/board-reply-2",
            conversation: design,
            sender: alex,
            minute: 96,
            text: "Agreed. Let’s keep the softer palette and give the headline a little more room.",
            thread: "showcase/board",
            reactions: [Reaction(emoji: "👍", count: 2, includesMe: false)]
        ),
        Line(
            id: "showcase/board-reply-3",
            conversation: design,
            sender: noah,
            minute: 99,
            text: "Checked the contrast and keyboard focus states. Both look good.",
            thread: "showcase/board"
        ),
        Line(
            id: "showcase/design-mention",
            conversation: design,
            sender: maya,
            minute: 110,
            text: "@Alex Morgan the updated brief is ready whenever you have a moment.",
            mentions: [Mention(target: .user(alex), start: 0, length: 12)],
            attachments: [brief]
        ),
        Line(
            id: "showcase/design-ready",
            conversation: design,
            sender: alex,
            minute: 120,
            text: "Love this direction. Let’s bring it to the launch review tomorrow. 🙌",
            reactions: [Reaction(emoji: "🙌", count: 3, includesMe: false)],
            edited: true
        ),
        Line(
            id: "showcase/launch-intro",
            conversation: launch,
            sender: priya,
            minute: 62,
            text: "The autumn launch is coming together. Here’s the preview for the studio."
        ),
        Line(
            id: "showcase/launch-link",
            conversation: launch,
            sender: priya,
            minute: 78,
            text: "Juniper — autumn field notes",
            links: [MessageLink(
                url: URL(string: "https://acme.example/juniper/autumn")!, start: 0, length: 28,
                preview: LinkPreview(
                    title: "Small details. Better days.",
                    snippet: "A small collection for slower, better everyday moments.",
                    imageURL: URL(string: "https://media.acme.example/showcase/launch-preview.png"),
                    imageWidth: 1200,
                    imageHeight: 630,
                    domain: "acme.example"
                )
            )]
        ),
        Line(
            id: "showcase/checklist",
            conversation: launch,
            sender: alex,
            minute: 100,
            text: "The last few things before launch:\n\n✓ Brand direction\n✓ Final copy\n"
                + "✓ Accessibility review\n○ Artwork exports\n○ Studio preview",
            reactions: [Reaction(emoji: "✅", count: 3, includesMe: true)],
            attachments: [checklist]
        ),
        Line(
            id: "showcase/checklist-reply-1",
            conversation: launch,
            sender: noah,
            minute: 104,
            text: "Keyboard pass is done, including the mobile menu.",
            thread: "showcase/checklist"
        ),
        Line(
            id: "showcase/checklist-reply-2",
            conversation: launch,
            sender: maya,
            minute: 112,
            text: "I’ll export the artwork after lunch.",
            thread: "showcase/checklist"
        ),
        Line(
            id: "showcase/launch-all",
            conversation: launch,
            sender: priya,
            minute: 116,
            text: "@all launch review is tomorrow at 10. Bring your coffee and your last little fixes ☕",
            mentions: [Mention(target: .all, start: 0, length: 4)]
        ),
        Line(
            id: "showcase/build-1",
            conversation: engineering,
            sender: noah,
            minute: 20,
            text: "The preview build is ready. Smaller images, better keyboard navigation, "
                + "and no layout jumps."
        ),
        Line(
            id: "showcase/build-card",
            conversation: engineering,
            sender: bot,
            minute: 55,
            text: "",
            cards: [buildCard]
        ),
        Line(
            id: "showcase/build-3",
            conversation: engineering,
            sender: ren,
            minute: 81,
            text: "Just checked it on a smaller window. Everything stays where it should.",
            reactions: [Reaction(emoji: "🚀", count: 2, includesMe: true)]
        ),
        Line(
            id: "showcase/announce-1",
            conversation: announcements,
            sender: julia,
            minute: -1420,
            text: "Welcome to Juniper Studio! A place for thoughtful work and good conversations. 🌱"
        ),
        Line(
            id: "showcase/announce-2",
            conversation: announcements,
            sender: julia,
            minute: 32,
            text: "Studio lunch on Thursday. Add your favorite local spot in a reply!",
            reactions: [
                Reaction(emoji: "🍜", count: 4, includesMe: false),
                Reaction(emoji: "🥗", count: 2, includesMe: true)
            ]
        ),
        Line(
            id: "showcase/reading-1",
            conversation: reading,
            sender: sam,
            minute: -1370,
            text: "This week’s small discovery: leaving a little more space around the things that matter."
        ),
        Line(
            id: "showcase/reading-2",
            conversation: reading,
            sender: maya,
            minute: -1310,
            text: "A good reminder for design reviews, too. Fewer slides, better conversations."
        )
    ]

    static let buildCard = AppCard(
        header: AppCard.Header(
            title: RichText("Preview is ready"),
            subtitle: RichText("Juniper / autumn launch")
        ),
        sections: [AppCard.Section(widgets: [
            .text(RichText(runs: [
                RichText.Run(text: "All checks passed. ", bold: true),
                RichText.Run(text: "Ready for a fresh pair of eyes.", italic: true)
            ])),
            .decorated(AppCard.Decorated(
                top: RichText("Build 128"),
                content: RichText("Preview environment"),
                bottom: RichText("Design, copy and keyboard checks complete")
            )),
            .image(AppCard.Picture(
                url: URL(string: "https://media.acme.example/showcase/launch-preview.png")!,
                aspectRatio: 1200.0 / 630,
                altText: "Juniper autumn collection artwork"
            )),
            .divider,
            .buttons([LinkButton(
                label: "View preview",
                url: URL(string: "https://acme.example/juniper/preview")!
            )])
        ])]
    )
}
