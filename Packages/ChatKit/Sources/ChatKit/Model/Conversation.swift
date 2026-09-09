import Foundation

/// One thing in the sidebar: a DM, a group chat, a DM with an app, a space,
/// or the space a scheduled meeting was created for.
///
/// The identity of a conversation is `id` alone. Everything else is a snapshot
/// that a later `conversationUpdated` event may replace wholesale, which is why
/// every field is a plain value and nothing here is a reference.
public struct Conversation: Codable, Hashable, Sendable {
    public var id: ID
    public var kind: Kind

    /// `nil` means the backend has no server-provided title and the client must
    /// derive one from `members` — the normal case for a DM, where Chat sends
    /// no name at all. An empty string is *not* the same thing: it is a title
    /// the server really sent, and deriving over it would be wrong.
    public var title: String?
    public var avatarURL: URL?

    /// Used for sidebar ordering. `nil` means "never, or not known yet", which
    /// a client should sort below anything with a timestamp rather than
    /// treating as the epoch.
    public var lastActivity: Date?

    /// How many messages are unread, **when the backend can say**.
    ///
    /// Google's `unread_message_count` arrives on every conversation and is
    /// always `0` - measured across all 220 on a real account
    /// (`findings.md` §37.8). So a client that renders this number alone
    /// renders nothing, forever, which is exactly what happened. Use
    /// `hasUnread` for whether to mark a conversation at all, and this only
    /// when it is greater than zero.
    public var unreadCount: Int

    /// Whether anything is unread, independent of how many.
    ///
    /// Separate from `unreadCount` because the two answer different questions
    /// and the wire can supply one without the other: Chat gives a read
    /// *position* and the newest message's time, from which "is there
    /// anything newer than what I have read" follows, while the count itself
    /// is always zero. Collapsing them - storing `1` to mean "some" - would
    /// put a fiction in the model rather than in the server's answer, and
    /// anything later summing counts would be lied to by us.
    ///
    /// Absent means `false`, the same rule `Capabilities` follows: an older
    /// peer that does not send this must not have its conversations marked
    /// unread on a guess.
    public var hasUnread: Bool

    /// The `{MUTED, UNMUTED}` axis of Chat's notification settings. Kept
    /// separate from `notificationLevel`, which is the other axis; see
    /// `NotificationLevel` for why they are not merged.
    public var isMuted: Bool
    public var notificationLevel: NotificationLevel

    /// Identifiers only. A client resolves them through its own member store,
    /// because the same member appears in many conversations and copying the
    /// records into each one would make every membership change a fan-out.
    public var members: [Member.ID]

    /// Whether replies form threads. Chat calls the other case a "flat" group,
    /// and the difference is structural, not cosmetic: in a flat group every
    /// message is its own topic.
    public var isThreaded: Bool

    public init(
        id: ID,
        kind: Kind,
        title: String? = nil,
        avatarURL: URL? = nil,
        lastActivity: Date? = nil,
        unreadCount: Int = 0,
        hasUnread: Bool = false,
        isMuted: Bool = false,
        notificationLevel: NotificationLevel = .always,
        members: [Member.ID] = [],
        isThreaded: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.avatarURL = avatarURL
        self.lastActivity = lastActivity
        self.unreadCount = unreadCount
        self.hasUnread = hasUnread
        self.isMuted = isMuted
        self.notificationLevel = notificationLevel
        self.members = members
        self.isThreaded = isThreaded
    }
}

// MARK: - Identifier

public extension Conversation {
    /// A conversation identifier.
    ///
    /// Unlike `Message.ID`, this one has a documented shape: `"dm:<id>"` or
    /// `"space:<id>"`, mirroring the internal protocol's `GroupId`, which is a
    /// `oneof` of exactly `space_id` and `dm_id`. The prefix is part of the
    /// identifier because the two id spaces are separate — a bare id does not
    /// say which one it came from — and because a group DM and an app DM are
    /// both `dm:` even though `Kind` distinguishes them.
    ///
    /// It is a struct rather than a `typealias String` so that passing a
    /// `Member.ID` where a `Conversation.ID` belongs is a compile error.
    struct ID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public init(_ rawValue: String) {
            self.rawValue = rawValue
        }

        public var description: String {
            rawValue
        }

        public init(from decoder: any Decoder) throws {
            try self.init(WireString.decode(from: decoder))
        }

        public func encode(to encoder: any Encoder) throws {
            try WireString.encode(rawValue, to: encoder)
        }
    }
}

// MARK: - Kind

public extension Conversation {
    /// What sort of conversation this is.
    ///
    /// Open, like every enum crossing this seam: an unrecognised wire string
    /// becomes `.unknown(raw)` and encodes back to that same string, so a
    /// backend that learns a new conversation type does not break a client
    /// built before it.
    enum Kind: Codable, Hashable, Sendable {
        case directMessage
        case groupDirectMessage
        case appDirectMessage
        case space

        /// A space created for a scheduled meeting, named after the calendar
        /// event - 187 of the 220 conversations on the account this was built
        /// against.
        ///
        /// **The name is a product decision, not a documented protocol
        /// fact.** These arrive as `attribute_checker_group_type` **10**,
        /// which no vendored reference proto names, so what Google calls the
        /// type is unknown (`findings.md` §37.4). What is measured is that
        /// value 10 is a space-namespace type and that all 187 of them are
        /// titled after calendar events; the owner identified them as their
        /// Meet conversations and chose the name. If value 10 turns out to be
        /// broader than meetings, this label is what will be wrong - not the
        /// mapping, which is keyed on the number.
        case meetChat

        case unknown(String)

        init(wire: String) {
            switch wire {
            case "directMessage": self = .directMessage
            case "groupDirectMessage": self = .groupDirectMessage
            case "appDirectMessage": self = .appDirectMessage
            case "space": self = .space
            case "meetChat": self = .meetChat
            default: self = .unknown(wire)
            }
        }

        var wire: String {
            switch self {
            case .directMessage: "directMessage"
            case .groupDirectMessage: "groupDirectMessage"
            case .appDirectMessage: "appDirectMessage"
            case .space: "space"
            case .meetChat: "meetChat"
            case let .unknown(raw): raw
            }
        }

        public init(from decoder: any Decoder) throws {
            try self.init(wire: WireString.decode(from: decoder))
        }

        public func encode(to encoder: any Encoder) throws {
            try WireString.encode(wire, to: encoder)
        }
    }
}

// MARK: - Coding

public extension Conversation {
    internal enum CodingKeys: String, CodingKey {
        case id
        case kind
        case title
        case avatarURL
        case lastActivity
        case unreadCount
        case hasUnread
        case isMuted
        case notificationLevel
        case members
        case isThreaded
    }

    /// `id` and `kind` are required; everything else falls back to the same
    /// value the memberwise initialiser defaults to.
    ///
    /// The encoder always writes those fields, so absence means the frame came
    /// from a peer that did not have them — and in every case the default is
    /// the assumption that claims least: no title, no activity, nothing unread,
    /// not muted, no members, not threaded.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(ID.self, forKey: .id),
            kind: container.decode(Kind.self, forKey: .kind),
            title: container.decodeIfPresent(String.self, forKey: .title),
            avatarURL: container.decodeIfPresent(URL.self, forKey: .avatarURL),
            lastActivity: container.decodeWireIfPresent(Date.self, forKey: .lastActivity),
            unreadCount: container.decodeIfPresent(Int.self, forKey: .unreadCount) ?? 0,
            hasUnread: container.decodeIfPresent(Bool.self, forKey: .hasUnread) ?? false,
            isMuted: container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false,
            notificationLevel: container.decodeIfPresent(
                NotificationLevel.self, forKey: .notificationLevel
            ) ?? .always,
            members: container.decodeIfPresent([Member.ID].self, forKey: .members) ?? [],
            isThreaded: container.decodeIfPresent(Bool.self, forKey: .isThreaded) ?? false
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(avatarURL, forKey: .avatarURL)
        try container.encodeWireIfPresent(lastActivity, forKey: .lastActivity)
        try container.encode(unreadCount, forKey: .unreadCount)
        try container.encode(hasUnread, forKey: .hasUnread)
        try container.encode(isMuted, forKey: .isMuted)
        try container.encode(notificationLevel, forKey: .notificationLevel)
        try container.encode(members, forKey: .members)
        try container.encode(isThreaded, forKey: .isThreaded)
    }
}
