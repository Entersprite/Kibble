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

    /// The choices that actually make a sound - `choices` minus Off, for a
    /// picker that only ever needs the audible ones.
    public static let audibleChoices: [Delivery] = [.bannerAndSound, .banner, .notificationCenter]

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

/// What notifies (spec §3): every message, or only the ones that mention this
/// person. Delivery Off is Nothing, whatever this says - the two fields are
/// independent, same as every other field on a `NotificationRule`.
public enum NotifyAbout: Codable, Hashable, Sendable {
    case allMessages
    case mentions
    /// A value a newer build wrote. Resolves as "inherit", never as a guess.
    case unknown(String)

    init(wire: String) {
        switch wire {
        case "allMessages": self = .allMessages
        case "mentions": self = .mentions
        default: self = .unknown(wire)
        }
    }

    var wire: String {
        switch self {
        case .allMessages: "allMessages"
        case .mentions: "mentions"
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
    /// What notifies (spec §3): every message, or only mentions. Delivery Off
    /// is Nothing, whatever this says.
    public var notifyAbout: NotifyAbout?

    /// Fields a newer build wrote and this one cannot name - kept, so that
    /// re-saving a record on an older build does not destroy them. Without
    /// this, sync (spec §6) would lose data every time an old client edited.
    public var unrecognisedFields: [String: JSONValue] = [:]

    public init(
        delivery: Delivery? = nil,
        showsPreview: Bool? = nil,
        showsUnread: Bool? = nil,
        countsInBadge: Bool? = nil,
        readReceipts: Bool? = nil,
        notifyAbout: NotifyAbout? = nil
    ) {
        self.delivery = delivery
        self.showsPreview = showsPreview
        self.showsUnread = showsUnread
        self.countsInBadge = countsInBadge
        self.readReceipts = readReceipts
        self.notifyAbout = notifyAbout
    }

    /// Nothing overridden - what Reset to Defaults and Unmute leave behind.
    public var isEmpty: Bool {
        delivery == nil && showsPreview == nil && showsUnread == nil
            && countsInBadge == nil && readReceipts == nil && notifyAbout == nil
    }
}

extension NotificationRule: Codable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case delivery, showsPreview, showsUnread, countsInBadge, readReceipts, notifyAbout
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
            readReceipts: container.decodeIfPresent(Bool.self, forKey: .readReceipts),
            notifyAbout: container.decodeIfPresent(NotifyAbout.self, forKey: .notifyAbout)
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
        try container.encodeIfPresent(notifyAbout, forKey: .notifyAbout)
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
    public var notifyAbout: NotifyAbout
    /// The first known delivery that is not Off in the chain this was
    /// resolved from, else the fallback's: what a level delivers as when its
    /// own All messages or Mentions only overrides an Off from above (see
    /// `NotificationRule.resolve`). Kept here because a flattened `delivery`
    /// of Off has lost which audible delivery sat beneath it, and the editors
    /// resolve one level below a flattened `inherited`. Never Off and never
    /// `.unknown`; `.bannerAndSound` on the built-in.
    public var audibleDelivery: Delivery

    public init(
        delivery: Delivery, showsPreview: Bool, showsUnread: Bool,
        countsInBadge: Bool, readReceipts: Bool, notifyAbout: NotifyAbout = .allMessages,
        audibleDelivery: Delivery = .bannerAndSound
    ) {
        self.delivery = delivery
        self.showsPreview = showsPreview
        self.showsUnread = showsUnread
        self.countsInBadge = countsInBadge
        self.readReceipts = readReceipts
        self.notifyAbout = notifyAbout
        self.audibleDelivery = audibleDelivery
    }

    /// What applies when nobody has said otherwise (spec §2.4).
    public static let builtIn = ResolvedRule(
        delivery: .bannerAndSound, showsPreview: true, showsUnread: true,
        countsInBadge: true, readReceipts: true, notifyAbout: .allMessages
    )
}

public extension NotificationRule {
    /// Meet Chats' default: 187 of the real account's 220 conversations
    /// (`findings.md` §37.4). A preset, not a record, so Reset to Defaults
    /// returns to it rather than to the global default.
    static let meetChatsPreset = NotificationRule(delivery: .off, showsUnread: false, countsInBadge: false)

    /// The first value per field, most specific first. The chain is data, so a
    /// later "this device only" layer is one more entry (spec §2.4).
    ///
    /// **Delivery has one exception: a lower level overrides a higher one.**
    /// The owner's rule (2026-09-27): "Lower level overrides higher level
    /// always ... global acts like a 'default' so if no rules are applied
    /// below, then global rules lives." So a level whose own record carries a
    /// known `notifyAbout` - All messages or Mentions only - overrides an Off
    /// inherited from any level above it (more general, later in the chain),
    /// and delivers as `audibleDelivery`: the first audible delivery below it,
    /// else the built-in Banner and sound (mentions spec §4, as amended).
    ///
    /// - An Off at the same or a more specific level still wins: a
    ///   conversation's own Nothing, or a mute, beats its section's Mentions
    ///   only, and a record that says `delivery: .off` is Nothing whatever its
    ///   `notifyAbout` says.
    /// - An unknown `notifyAbout` never overrides: it resolves as inherit.
    /// - A record with no `notifyAbout`, as every record written before this
    ///   rule is, resolves exactly as it did.
    ///
    /// Decided here, at resolve time, rather than by writing a delivery when
    /// the choice is made, because a written delivery made the outcome depend
    /// on the order of the user's edits (final review, Important 1).
    /// `resolve(prefix, below: resolve(suffix))` equals `resolve(prefix +
    /// suffix)`, which is what lets an editor resolve one level below a
    /// flattened `inherited` and agree with `NotificationSettings`;
    /// `NotifyOverrideTests.resolutionComposes` pins it.
    static func resolve(
        _ chain: [NotificationRule],
        below fallback: ResolvedRule = .builtIn
    ) -> ResolvedRule {
        let audible = chain.lazy.compactMap(\.delivery).first { $0.isKnown && $0 != .off }
            ?? fallback.audibleDelivery
        return ResolvedRule(
            delivery: delivery(of: chain, below: fallback, audible: audible),
            showsPreview: chain.lazy.compactMap(\.showsPreview).first ?? fallback.showsPreview,
            showsUnread: chain.lazy.compactMap(\.showsUnread).first ?? fallback.showsUnread,
            countsInBadge: chain.lazy.compactMap(\.countsInBadge).first ?? fallback.countsInBadge,
            readReceipts: chain.lazy.compactMap(\.readReceipts).first ?? fallback.readReceipts,
            notifyAbout: chain.lazy.compactMap(\.notifyAbout).first(where: \.isKnown) ?? fallback.notifyAbout,
            audibleDelivery: audible
        )
    }

    /// `resolve`'s delivery. `deciding` is the first level with a known
    /// delivery; an own known `notifyAbout` strictly before it overrides its
    /// Off. No level before `deciding` has a delivery, so the first audible
    /// delivery in the chain is also the first below the overriding level.
    private static func delivery(
        of chain: [NotificationRule],
        below fallback: ResolvedRule,
        audible: Delivery
    ) -> Delivery {
        let overriding = chain.firstIndex { $0.notifyAbout?.isKnown == true }
        guard let deciding = chain.firstIndex(where: { $0.delivery?.isKnown == true }),
              let delivery = chain[deciding].delivery
        else {
            if fallback.delivery == .off, overriding != nil {
                return fallback.audibleDelivery
            }
            return fallback.delivery
        }
        if delivery == .off, let overriding, overriding < deciding {
            return audible
        }
        return delivery
    }
}
