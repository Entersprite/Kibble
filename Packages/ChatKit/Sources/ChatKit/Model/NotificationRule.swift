import Foundation

/// How a notification is delivered - the four things macOS lets an app choose
/// per notification (spec §1). Time Sensitive and Critical are absent on
/// purpose: both need an entitlement this build cannot carry, and
/// `CLAUDE.md` forbids drawing a control the app cannot honour.
public enum Delivery: Codable, Hashable, Sendable {
    case off
    case notificationCenter
    case banner
    case bannerAndSound
    /// A value a newer build wrote. Resolves as "inherit", never as a guess.
    case unknown(String)

    /// What a person can pick, in the order a menu shows them.
    public static let choices: [Delivery] = [.bannerAndSound, .banner, .notificationCenter, .off]

    init(wire: String) {
        switch wire {
        case "off": self = .off
        case "notificationCenter": self = .notificationCenter
        case "banner": self = .banner
        case "bannerAndSound": self = .bannerAndSound
        default: self = .unknown(wire)
        }
    }

    var wire: String {
        switch self {
        case .off: "off"
        case .notificationCenter: "notificationCenter"
        case .banner: "banner"
        case .bannerAndSound: "bannerAndSound"
        case let .unknown(raw): raw
        }
    }

    var isKnown: Bool {
        if case .unknown = self {
            return false
        }
        return true
    }

    public init(from decoder: any Decoder) throws {
        try self.init(wire: WireString.decode(from: decoder))
    }

    public func encode(to encoder: any Encoder) throws {
        try WireString.encode(wire, to: encoder)
    }
}

/// A sidebar section, as a notification rule sees it.
///
/// Lives here rather than in `DesignSystem.SidebarSections` so that the
/// heading a conversation is listed under and the section rule it obeys come
/// from one mapping and cannot disagree (spec §2.3).
public enum SectionKey: Codable, Hashable, Sendable {
    case directMessages
    case groupChats
    case spaces
    case apps
    case meetChats
    case other
    /// An unrecognised group type (its own sidebar heading) or a token a newer
    /// build wrote. Either way its rule is Other's - see `ruleSection`.
    case unknown(String)

    /// The sections a rule can be set for, in sidebar order.
    public static let ruleSections: [SectionKey] = [
        .directMessages, .groupChats, .spaces, .apps, .meetChats, .other
    ]

    public init(kind: Conversation.Kind) {
        switch kind {
        case .directMessage: self = .directMessages
        case .groupDirectMessage: self = .groupChats
        case .space: self = .spaces
        case .appDirectMessage: self = .apps
        case .meetChat: self = .meetChats
        case let .unknown(raw): self = raw.isEmpty ? .other : .unknown(raw)
        }
    }

    /// The section whose rule applies. Every unrecognised type shares Other's.
    public var ruleSection: SectionKey {
        if case .unknown = self {
            return .other
        }
        return self
    }

    init(wire: String) {
        switch wire {
        case "directMessages": self = .directMessages
        case "groupChats": self = .groupChats
        case "spaces": self = .spaces
        case "apps": self = .apps
        case "meetChats": self = .meetChats
        case "other": self = .other
        default: self = .unknown(wire)
        }
    }

    var wire: String {
        switch self {
        case .directMessages: "directMessages"
        case .groupChats: "groupChats"
        case .spaces: "spaces"
        case .apps: "apps"
        case .meetChats: "meetChats"
        case .other: "other"
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

/// One level's notification settings. Every field is optional: `nil` means
/// inherit from the next level down, field by field (spec §2.1).
public struct NotificationRule: Hashable, Sendable {
    public var delivery: Delivery?
    public var showsPreview: Bool?
    public var showsUnread: Bool?
    public var countsInBadge: Bool?
    public var readReceipts: Bool?

    /// Fields a newer build wrote and this one cannot name - kept, so that
    /// re-saving a record on an older build does not destroy them. Without
    /// this, sync (spec §6) would lose data every time an old client edited.
    public var unrecognisedFields: [String: JSONValue] = [:]

    public init(
        delivery: Delivery? = nil,
        showsPreview: Bool? = nil,
        showsUnread: Bool? = nil,
        countsInBadge: Bool? = nil,
        readReceipts: Bool? = nil
    ) {
        self.delivery = delivery
        self.showsPreview = showsPreview
        self.showsUnread = showsUnread
        self.countsInBadge = countsInBadge
        self.readReceipts = readReceipts
    }

    /// Nothing overridden - what Reset to Defaults and Unmute leave behind.
    public var isEmpty: Bool {
        delivery == nil && showsPreview == nil && showsUnread == nil
            && countsInBadge == nil && readReceipts == nil
    }
}

extension NotificationRule: Codable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case delivery, showsPreview, showsUnread, countsInBadge, readReceipts
    }

    struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? {
            nil
        }

        init(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue _: Int) {
            nil
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            delivery: container.decodeIfPresent(Delivery.self, forKey: .delivery),
            showsPreview: container.decodeIfPresent(Bool.self, forKey: .showsPreview),
            showsUnread: container.decodeIfPresent(Bool.self, forKey: .showsUnread),
            countsInBadge: container.decodeIfPresent(Bool.self, forKey: .countsInBadge),
            readReceipts: container.decodeIfPresent(Bool.self, forKey: .readReceipts)
        )
        let everything = try decoder.container(keyedBy: AnyKey.self)
        let known = Set(CodingKeys.allCases.map(\.rawValue))
        for key in everything.allKeys where !known.contains(key.stringValue) {
            unrecognisedFields[key.stringValue] = try everything.decode(JSONValue.self, forKey: key)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(delivery, forKey: .delivery)
        try container.encodeIfPresent(showsPreview, forKey: .showsPreview)
        try container.encodeIfPresent(showsUnread, forKey: .showsUnread)
        try container.encodeIfPresent(countsInBadge, forKey: .countsInBadge)
        try container.encodeIfPresent(readReceipts, forKey: .readReceipts)
        var extra = encoder.container(keyedBy: AnyKey.self)
        for (key, value) in unrecognisedFields {
            try extra.encode(value, forKey: AnyKey(stringValue: key))
        }
    }
}

/// A rule with every field decided - all the policy, the engine and the views
/// ever see. `delivery` is never `.unknown`: resolution skips those.
public struct ResolvedRule: Hashable, Sendable {
    public var delivery: Delivery
    public var showsPreview: Bool
    public var showsUnread: Bool
    public var countsInBadge: Bool
    public var readReceipts: Bool

    public init(
        delivery: Delivery, showsPreview: Bool, showsUnread: Bool,
        countsInBadge: Bool, readReceipts: Bool
    ) {
        self.delivery = delivery
        self.showsPreview = showsPreview
        self.showsUnread = showsUnread
        self.countsInBadge = countsInBadge
        self.readReceipts = readReceipts
    }

    /// What applies when nobody has said otherwise (spec §2.4).
    public static let builtIn = ResolvedRule(
        delivery: .bannerAndSound, showsPreview: true, showsUnread: true,
        countsInBadge: true, readReceipts: true
    )
}

public extension NotificationRule {
    /// Meet Chats' default: 187 of the real account's 220 conversations
    /// (`findings.md` §37.4). A preset, not a record, so Reset to Defaults
    /// returns to it rather than to the global default.
    static let meetChatsPreset = NotificationRule(delivery: .off, showsUnread: false, countsInBadge: false)

    /// The first value per field, most specific first. The chain is data, so a
    /// later "this device only" layer is one more entry (spec §2.4).
    static func resolve(
        _ chain: [NotificationRule],
        below fallback: ResolvedRule = .builtIn
    ) -> ResolvedRule {
        ResolvedRule(
            delivery: chain.lazy.compactMap(\.delivery).first(where: \.isKnown) ?? fallback.delivery,
            showsPreview: chain.lazy.compactMap(\.showsPreview).first ?? fallback.showsPreview,
            showsUnread: chain.lazy.compactMap(\.showsUnread).first ?? fallback.showsUnread,
            countsInBadge: chain.lazy.compactMap(\.countsInBadge).first ?? fallback.countsInBadge,
            readReceipts: chain.lazy.compactMap(\.readReceipts).first ?? fallback.readReceipts
        )
    }
}
