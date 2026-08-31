import ChatKit
import Foundation

// MARK: - The demo world

public extension FixtureWorld {
    /// A believable workspace, for looking at.
    ///
    /// Every person, message and space here is invented. Nothing in this file
    /// came from a real account, which matters: fixtures get committed,
    /// screenshotted and pasted into issues.
    ///
    /// Kept apart from `minimal`, which the test suite uses, so that making the
    /// demo more convincing can never break a test asserting on counts.
    static let acme = Acme.world
}

/// The demo world's parts, as tables.
///
/// Tables rather than one long initialiser for two reasons: `lastActivity` is
/// derived from each conversation's own last message instead of being typed
/// twice and left to drift, and a table does not grow into a function body long
/// enough for swiftlint to reject.
public enum Acme {
    // MARK: People

    public static let alex = Member.ID("people/alex")
    public static let maya = Member.ID("people/maya")
    public static let dan = Member.ID("people/dan")
    public static let priya = Member.ID("people/priya")
    public static let tom = Member.ID("people/tom")
    public static let deployBot = Member.ID("apps/deploybot")

    // MARK: Conversations

    public static let priceEngine = Conversation.ID("space:price-engine")
    public static let storefront = Conversation.ID("space:storefront-web")
    public static let catalog = Conversation.ID("space:catalog-data")
    public static let launchTeam = Conversation.ID("dm:launch-team")
    public static let mayaDM = Conversation.ID("dm:maya")
    public static let danDM = Conversation.ID("dm:dan")

    /// A `space:` identifier even though the kind is unknown. On the wire a
    /// Meet chat still lives in one of the two documented id spaces, and
    /// inventing a third prefix would put a guess into the part of the model
    /// that is not guesswork. The *kind* is where the uncertainty belongs.
    public static let standup = Conversation.ID("space:meet-standup")

    /// 2026-08-31T09:00:00Z. A literal, because nothing in this package reads a
    /// clock.
    static let start = Date(timeIntervalSince1970: 1_788_166_800)

    static func at(_ minutes: Int) -> Date {
        start.addingTimeInterval(Double(minutes) * 60)
    }

    static let members: [Member] = [
        Member(
            id: alex, kind: .human, displayName: "Alex Carter",
            email: "alex@example.invalid", presence: .active
        ),
        Member(
            id: maya, kind: .human, displayName: "Maya Okafor",
            email: "maya@example.invalid", presence: .active
        ),
        Member(
            id: dan, kind: .human, displayName: "Dan Reyes",
            email: "dan@example.invalid", presence: .active
        ),
        Member(
            id: priya, kind: .human, displayName: "Priya Shah",
            email: "priya@example.invalid", presence: .inactive
        ),
        Member(
            id: tom, kind: .human, displayName: "Tom Whitfield",
            email: "tom@example.invalid", presence: .doNotDisturb
        ),
        // No display name and no email, deliberately: under user authentication
        // an app is not a Google account and has no profile, so
        // DisplayNameResolution has to cope with exactly this. The demo world
        // should contain the awkward case, not only the tidy ones.
        Member(id: deployBot, kind: .app)
    ]

    /// Conversations without `lastActivity`; `world` fills that in from the
    /// messages so the two can never disagree.
    static let baseConversations: [Conversation] = [
        Conversation(
            id: priceEngine, kind: .space, title: "price-engine",
            members: [alex, maya, dan, priya, deployBot], isThreaded: true
        ),
        Conversation(
            id: storefront, kind: .space, title: "storefront-web",
            unreadCount: 5, members: [alex, priya, tom]
        ),
        Conversation(
            id: catalog, kind: .space, title: "catalog-data",
            notificationLevel: .less, members: [alex, tom]
        ),
        Conversation(
            id: launchTeam, kind: .groupDirectMessage, title: "Wheel launch team",
            unreadCount: 2, members: [alex, maya, dan, priya]
        ),
        Conversation(
            id: standup, kind: .unknown("meetCall"), title: "Pricing standup",
            members: [alex, maya, dan]
        ),
        // title nil, not "": a DM has no server-provided name and the client
        // derives one from its members.
        Conversation(
            id: mayaDM, kind: .directMessage, title: nil,
            unreadCount: 1, members: [alex, maya]
        ),
        Conversation(
            id: danDM, kind: .directMessage, title: nil,
            isMuted: true, members: [alex, dan]
        )
    ]

    static let world: FixtureWorld = {
        let messages = allMessages()
        let latest = Dictionary(grouping: messages, by: \.conversationID)
            .compactMapValues { $0.map(\.createdAt).max() }
        return FixtureWorld(
            me: alex,
            members: members,
            conversations: baseConversations.map { conversation in
                var filled = conversation
                filled.lastActivity = latest[conversation.id]
                return filled
            },
            messages: messages,
            startedAt: messages.map(\.createdAt).max() ?? start
        )
    }()
}
