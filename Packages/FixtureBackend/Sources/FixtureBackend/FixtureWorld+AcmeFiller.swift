import ChatKit
import Foundation

// MARK: - Filler, so the sidebar is long enough to scroll

extension Acme {
    /// A sidebar row that exists to give the list length.
    ///
    /// Its own table, and its own file, because these carry no narrative: the
    /// hand-written conversations in `+AcmeContent` are there to be read in
    /// a screenshot, and mixing twenty filler rows into them would bury the ones
    /// that say something.
    ///
    /// **Each one still gets a message.** `DemoWorldTests
    /// .everyDemoConversationHasSomethingToShow` requires it, and rightly - a
    /// conversation that opens to an empty transcript is a worse demo than one
    /// that does not exist.
    struct Filler {
        let slug: String
        let title: String
        let kind: Conversation.Kind
        let sender: Member.ID
        let text: String
        /// Minutes from `Acme.start`, as everywhere else here. Distinct per
        /// row so the sidebar's ordering is total and never wobbles.
        let minute: Int
        var unread = 0
        var muted = false
        var others: [Member.ID] = []

        var id: Conversation.ID {
            Conversation.ID("\(kind == .space ? "space" : "dm"):\(slug)")
        }

        var conversation: Conversation {
            Conversation(
                id: id,
                kind: kind,
                title: title,
                unreadCount: unread,
                isMuted: muted,
                members: [alex] + others,
                repliesEnabled: true
            )
        }

        var message: Message {
            Message(
                id: Message.ID("msg:\(slug)"),
                conversationID: id,
                threadID: MessageThread.ID("topic:\(slug)"),
                sender: sender,
                text: text,
                createdAt: at(minute)
            )
        }
    }

    static let filler: [Filler] = [
        Filler(
            slug: "warehouse-ops",
            title: "warehouse-ops",
            kind: .space,
            sender: tom,
            text: "Bay 4 pallet racking is back in service.",
            minute: -1180,
            others: [tom, dan]
        ),
        Filler(
            slug: "supplier-api",
            title: "supplier-api",
            kind: .space,
            sender: dan,
            text: "Michelin sandbox is returning 502s again.",
            minute: -1140,
            unread: 3,
            others: [
                dan,
                priya
            ]
        ),
        Filler(
            slug: "checkout-bugs",
            title: "checkout-bugs",
            kind: .space,
            sender: priya,
            text: "Repro for the duplicate-tax bug is in the ticket.",
            minute: -1100,
            others: [
                priya,
                maya
            ]
        ),
        Filler(
            slug: "seo-content",
            title: "seo-content",
            kind: .space,
            sender: maya,
            text: "Catalog landing pages are indexed.",
            minute: -1060,
            others: [maya]
        ),
        Filler(
            slug: "mobile-app",
            title: "mobile-app",
            kind: .space,
            sender: dan,
            text: "TestFlight build 214 is up.",
            minute: -1020,
            unread: 1,
            others: [dan, tom]
        ),
        Filler(
            slug: "design-review",
            title: "design-review",
            kind: .space,
            sender: priya,
            text: "Thursday's review is moved to 15:00.",
            minute: -980,
            others: [priya, maya, tom]
        ),
        Filler(
            slug: "oncall",
            title: "oncall",
            kind: .space,
            sender: tom,
            text: "I have the pager this week.",
            minute: -940,
            others: [tom, dan]
        ),
        Filler(
            slug: "incidents",
            title: "incidents",
            kind: .space,
            sender: deployBot,
            text: "INC-0421 resolved after 12 minutes.",
            minute: -900,
            muted: true,
            others: [
                deployBot,
                dan
            ]
        ),
        Filler(
            slug: "data-platform",
            title: "data-platform",
            kind: .space,
            sender: maya,
            text: "Nightly warehouse load finished early.",
            minute: -860,
            others: [maya, priya]
        ),
        Filler(
            slug: "ml-pricing",
            title: "ml-pricing",
            kind: .space,
            sender: maya,
            text: "New elasticity model is behind a flag.",
            minute: -820,
            unread: 7,
            others: [maya, dan]
        ),
        Filler(
            slug: "customer-support",
            title: "customer-support",
            kind: .space,
            sender: priya,
            text: "Queue is under 20 for the first time this month.",
            minute: -780,
            others: [priya, tom]
        ),
        Filler(
            slug: "returns-flow",
            title: "returns-flow",
            kind: .space,
            sender: tom,
            text: "Label generation is fixed for Canada.",
            minute: -740,
            others: [tom]
        ),
        Filler(
            slug: "payments",
            title: "payments",
            kind: .space,
            sender: dan,
            text: "Stripe webhook retries are configured.",
            minute: -700,
            others: [dan, priya]
        ),
        Filler(
            slug: "tax-engine",
            title: "tax-engine",
            kind: .space,
            sender: priya,
            text: "Avalara sandbox credentials rotated.",
            minute: -660,
            muted: true,
            others: [priya]
        ),
        Filler(
            slug: "inventory-sync",
            title: "inventory-sync",
            kind: .space,
            sender: deployBot,
            text: "Sync completed: 38k rows, 0 errors.",
            minute: -620,
            others: [deployBot, maya]
        ),
        Filler(
            slug: "vendor-portal",
            title: "vendor-portal",
            kind: .space,
            sender: maya,
            text: "Two vendors are onboarded to the new portal.",
            minute: -580,
            others: [maya, tom]
        ),
        Filler(
            slug: "marketing",
            title: "marketing",
            kind: .space,
            sender: priya,
            text: "Winter campaign creative is approved.",
            minute: -540,
            unread: 2,
            others: [priya, maya]
        ),
        Filler(
            slug: "analytics",
            title: "analytics",
            kind: .space,
            sender: dan,
            text: "Funnel dashboard is rebuilt on the new tables.",
            minute: -500,
            others: [dan, maya]
        ),
        Filler(
            slug: "release-notes",
            title: "release-notes",
            kind: .space,
            sender: deployBot,
            text: "v2.14.0 shipped to production.",
            minute: -460,
            others: [deployBot]
        ),
        Filler(
            slug: "platform-arch",
            title: "platform-arch",
            kind: .space,
            sender: tom,
            text: "RFC for the catalog cache is open for comments.",
            minute: -420,
            others: [
                tom,
                dan,
                maya
            ]
        ),
        Filler(
            slug: "q4-planning",
            title: "Q4 planning",
            kind: .groupDirectMessage,
            sender: maya,
            text: "Draft roadmap is in the doc.",
            minute: -380,
            unread: 4,
            others: [maya, dan, priya]
        ),
        Filler(
            slug: "hiring-loop",
            title: "Hiring loop",
            kind: .groupDirectMessage,
            sender: priya,
            text: "Two onsites confirmed for next week.",
            minute: -340,
            others: [priya, tom]
        ),
        Filler(
            slug: "offsite-crew",
            title: "Offsite crew",
            kind: .groupDirectMessage,
            sender: dan,
            text: "Booking the Thursday dinner now.",
            minute: -300,
            muted: true,
            others: [dan, maya, tom]
        )
    ]
}
