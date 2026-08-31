import Foundation

/// One thing in the sidebar: a DM, a group DM, a DM with an app, or a space.
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
    public var unreadCount: Int

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
        case unknown(String)

        init(wire: String) {
            switch wire {
            case "directMessage": self = .directMessage
            case "groupDirectMessage": self = .groupDirectMessage
            case "appDirectMessage": self = .appDirectMessage
            case "space": self = .space
            default: self = .unknown(wire)
            }
        }

        var wire: String {
            switch self {
            case .directMessage: "directMessage"
            case .groupDirectMessage: "groupDirectMessage"
            case .appDirectMessage: "appDirectMessage"
            case .space: "space"
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
        try container.encode(isMuted, forKey: .isMuted)
        try container.encode(notificationLevel, forKey: .notificationLevel)
        try container.encode(members, forKey: .members)
        try container.encode(isThreaded, forKey: .isThreaded)
    }
}
