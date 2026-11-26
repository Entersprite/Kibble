import ChatKit
import Foundation

public extension FixtureWorld {
    /// A fictional design studio with screenshot-ready conversations and bundled media.
    /// Kept separate from the small worlds used by behavioral regression tests.
    static let showcase = Showcase.world
}

public enum Showcase {
    public static let alex = Member.ID("showcase/alex")
    public static let maya = Member.ID("showcase/maya")
    public static let noah = Member.ID("showcase/noah")
    public static let priya = Member.ID("showcase/priya")
    public static let sam = Member.ID("showcase/sam")
    public static let julia = Member.ID("showcase/julia")
    public static let ren = Member.ID("showcase/ren")
    public static let bot = Member.ID("showcase/studio-bot")

    public static let design = Conversation.ID("showcase/design")
    public static let launch = Conversation.ID("showcase/launch")
    public static let coffee = Conversation.ID("showcase/coffee")
    public static let engineering = Conversation.ID("showcase/engineering")
    public static let announcements = Conversation.ID("showcase/announcements")
    public static let reading = Conversation.ID("showcase/reading")
    public static let mayaDM = Conversation.ID("showcase/dm-maya")
    public static let noahDM = Conversation.ID("showcase/dm-noah")
    public static let priyaDM = Conversation.ID("showcase/dm-priya")
    public static let samDM = Conversation.ID("showcase/dm-sam")
    public static let juliaDM = Conversation.ID("showcase/dm-julia")
    public static let botDM = Conversation.ID("showcase/dm-bot")
    public static let launchCrew = Conversation.ID("showcase/launch-crew")
    public static let weekend = Conversation.ID("showcase/weekend")
    public static let standupPrevious = Conversation.ID("showcase/standup-previous")
    public static let standup = Conversation.ID("showcase/standup")
    public static let critique = Conversation.ID("showcase/critique")
    public static let oneOff = Conversation.ID("showcase/one-off")

    /// 2026-10-18T08:00:00Z; all dates advance from this fixed instant.
    static let start = Date(timeIntervalSince1970: 1_792_310_400)
    static func at(_ minute: Int) -> Date {
        start.addingTimeInterval(Double(minute) * 60)
    }

    static let members: [Member] = [
        Member(
            id: alex,
            kind: .human,
            displayName: "Alex Morgan",
            email: "alex@example.invalid",
            presence: .active,
            status: MemberStatus(emoji: "🌿", text: "Making room for good ideas")
        ),
        Member(
            id: maya,
            kind: .human,
            displayName: "Maya Chen",
            email: "maya@example.invalid",
            presence: .active,
            status: MemberStatus(emoji: "🎨", text: "Exploring the autumn palette")
        ),
        Member(
            id: noah,
            kind: .human,
            displayName: "Noah Brooks",
            email: "noah@example.invalid",
            presence: .active,
            status: MemberStatus(text: "Building something small and useful")
        ),
        Member(
            id: priya,
            kind: .human,
            displayName: "Priya Shah",
            email: "priya@example.invalid",
            presence: .doNotDisturb,
            status: MemberStatus(emoji: "✍️", text: "A little writing time")
        ),
        Member(
            id: sam,
            kind: .human,
            displayName: "Sam Rivera",
            email: "sam@example.invalid",
            presence: .inactive,
            status: MemberStatus(emoji: "☕", text: "Back after coffee")
        ),
        Member(
            id: julia,
            kind: .human,
            displayName: "Julia Park",
            email: "julia@example.invalid",
            presence: .active,
            calendar: CalendarSchedule(entries: [.init(
                start: start, end: at(240), kind: .inMeeting, until: at(240)
            )], validUntil: nil)
        ),
        Member(
            id: ren,
            kind: .human,
            displayName: "Ren Sato",
            email: "ren@example.invalid",
            presence: .inactive
        ),
        Member(id: bot, kind: .app, displayName: "Studio Bot")
    ]

    public static let directory: [Member] = [
        Member(
            id: .init("showcase/directory-olive"),
            kind: .human,
            displayName: "Olive Bennett",
            email: "olive@example.invalid"
        ),
        Member(
            id: .init("showcase/directory-elliot"),
            kind: .human,
            displayName: "Elliot James",
            email: "elliot@example.invalid"
        ),
        Member(
            id: .init("showcase/directory-zara"),
            kind: .human,
            displayName: "Zara Ali",
            email: "zara@example.invalid"
        )
    ]

    static let conversations: [Conversation] = [
        Conversation(
            id: design,
            kind: .space,
            title: "Design studio",
            hasUnread: true,
            members: [alex, maya, noah, priya, julia],
            memberCount: 5,
            repliesEnabled: true,
            hasUnreadThread: true
        ),
        Conversation(
            id: launch,
            kind: .space,
            title: "Autumn launch",
            hasUnread: true,
            members: [alex, maya, noah, priya, bot],
            memberCount: 5,
            repliesEnabled: true
        ),
        Conversation(
            id: coffee,
            kind: .space,
            title: "The coffee corner",
            members: [alex, maya, noah, priya, sam, julia, ren],
            memberCount: 7,
            repliesEnabled: true
        ),
        Conversation(
            id: engineering,
            kind: .space,
            title: "Build & ship",
            members: [alex, noah, ren, bot],
            memberCount: 4,
            repliesEnabled: true
        ),
        Conversation(
            id: announcements,
            kind: .space,
            title: "Studio announcements",
            hasUnread: true,
            members: [alex, maya, noah, priya, sam, julia, ren],
            memberCount: 7,
            repliesEnabled: true
        ),
        Conversation(
            id: reading,
            kind: .space,
            title: "The reading room",
            isMuted: true,
            notificationLevel: .less,
            members: [alex, maya, priya, sam],
            memberCount: 4,
            repliesEnabled: true
        ),
        Conversation(
            id: mayaDM,
            kind: .directMessage,
            hasUnread: true,
            members: [alex, maya],
            repliesEnabled: true
        ),
        Conversation(id: noahDM, kind: .directMessage, members: [alex, noah], repliesEnabled: true),
        Conversation(id: priyaDM, kind: .directMessage, members: [alex, priya], repliesEnabled: true),
        Conversation(
            id: samDM,
            kind: .directMessage,
            isMuted: true,
            members: [alex, sam],
            repliesEnabled: true
        ),
        Conversation(id: juliaDM, kind: .directMessage, members: [alex, julia], repliesEnabled: true),
        Conversation(id: botDM, kind: .appDirectMessage, members: [alex, bot], repliesEnabled: true),
        Conversation(
            id: launchCrew,
            kind: .groupDirectMessage,
            title: "Launch crew",
            hasUnread: true,
            members: [alex, maya, noah, priya],
            memberCount: 4,
            repliesEnabled: true
        ),
        Conversation(
            id: weekend,
            kind: .groupDirectMessage,
            title: "Weekend club",
            members: [alex, maya, sam, julia],
            memberCount: 4,
            repliesEnabled: true
        )
    ] + meetingConversations + extraConversations

    static let world: FixtureWorld = {
        let tables: [[Line]] = [studioLines, directLines, socialLines, meetingLines, extraLines]
        let unsorted: [Message] = tables.flatMap { $0.map(\.message) }
        let messages = unsorted.sorted {
            $0.createdAt == $1.createdAt ? $0.id.rawValue < $1.id.rawValue : $0.createdAt < $1.createdAt
        }
        let grouped = Dictionary(grouping: messages, by: \.conversationID)
        var world = FixtureWorld(
            me: alex, members: members,
            conversations: conversations.map { original in
                var conversation = original
                let history = grouped[conversation.id] ?? []
                conversation.lastActivity = history.map(\.createdAt).max()
                let main = history.filter { !$0.isReply }
                conversation.latestMainMessageAt = main.map(\.createdAt).max()
                conversation.readPosition = conversation.hasUnread
                    ? main.first?.createdAt.addingTimeInterval(-60) : conversation.latestMainMessageAt
                conversation.unreadCount = conversation.hasUnread ? main.filter { $0.sender != alex }
                    .count : 0
                return conversation
            }, messages: messages, startedAt: at(180)
        )
        world.threadStates = [
            .init("showcase/board"): FixtureThreadState(isFollowed: true, readPosition: at(94)),
            .init("showcase/checklist"): FixtureThreadState(isFollowed: true, readPosition: at(104)),
            .init("showcase/dm-noah-review"): FixtureThreadState(isFollowed: true, readPosition: at(98))
        ]
        for index in world.conversations.indices {
            world.conversations[index].hasUnreadThread = world
                .hasUnreadThread(in: world.conversations[index].id)
        }
        return world
    }()
}

extension Showcase {
    struct Line {
        let id: String
        let conversation: Conversation.ID
        let sender: Member.ID
        let minute: Int
        let text: String
        var thread: String?
        var reactions: [Reaction] = []
        var mentions: [Mention] = []
        var attachments: [Attachment] = []
        var links: [MessageLink] = []
        var cards: [AppCard] = []
        var edited = false
        var deleted = false

        var message: Message {
            Message(
                id: .init(id), conversationID: conversation, threadID: .init(thread ?? id),
                sender: sender, text: deleted ? "" : text, createdAt: at(minute),
                editedAt: edited ? at(minute + 1) : nil, isDeleted: deleted,
                reactions: reactions, attachments: attachments, mentions: mentions,
                links: links, cards: cards, isReply: thread != nil
            )
        }
    }
}
