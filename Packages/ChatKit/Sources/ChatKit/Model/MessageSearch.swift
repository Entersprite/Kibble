import Foundation

/// A message search (search spec §2): the person's words and the filters a
/// backend may honor (`Capabilities.messageSearchFilters`).
///
/// **A missing key decodes as "not set".** A query from an older client asks
/// for less, never for something it did not mean. How `text` matches is the
/// backend's own.
public struct MessageSearchQuery: Codable, Hashable, Sendable {
    public var text: String
    public var from: Member.ID?
    public var conversation: Conversation.ID?
    /// Only messages created before this instant ("Older than a week").
    public var olderThan: Date?
    /// Only messages created at or after this instant.
    public var newerThan: Date?
    public var hasFile: Bool
    public var hasLink: Bool
    public var mentionsMe: Bool
    public var order: MessageSearchOrder

    public init(
        text: String = "",
        from: Member.ID? = nil,
        conversation: Conversation.ID? = nil,
        olderThan: Date? = nil,
        newerThan: Date? = nil,
        hasFile: Bool = false,
        hasLink: Bool = false,
        mentionsMe: Bool = false,
        order: MessageSearchOrder = .relevance
    ) {
        self.text = text
        self.from = from
        self.conversation = conversation
        self.olderThan = olderThan
        self.newerThan = newerThan
        self.hasFile = hasFile
        self.hasLink = hasLink
        self.mentionsMe = mentionsMe
        self.order = order
    }

    /// Whether any filter is set. `text` and `order` are not filters.
    public var hasFilters: Bool {
        from != nil || conversation != nil || olderThan != nil || newerThan != nil
            || hasFile || hasLink || mentionsMe
    }
}

public extension MessageSearchQuery {
    internal enum CodingKeys: String, CodingKey {
        case text, from, conversation, olderThan, newerThan, hasFile, hasLink, mentionsMe, order
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func flag(_ key: CodingKeys) throws -> Bool {
            try container.decodeIfPresent(Bool.self, forKey: key) ?? false
        }
        try self.init(
            text: container.decodeIfPresent(String.self, forKey: .text) ?? "",
            from: container.decodeIfPresent(Member.ID.self, forKey: .from),
            conversation: container.decodeIfPresent(Conversation.ID.self, forKey: .conversation),
            olderThan: container.decodeWireIfPresent(Date.self, forKey: .olderThan),
            newerThan: container.decodeWireIfPresent(Date.self, forKey: .newerThan),
            hasFile: flag(.hasFile),
            hasLink: flag(.hasLink),
            mentionsMe: flag(.mentionsMe),
            order: container.decodeIfPresent(MessageSearchOrder.self, forKey: .order) ?? .relevance
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encodeIfPresent(from, forKey: .from)
        try container.encodeIfPresent(conversation, forKey: .conversation)
        try container.encodeWireIfPresent(olderThan, forKey: .olderThan)
        try container.encodeWireIfPresent(newerThan, forKey: .newerThan)
        try container.encode(hasFile, forKey: .hasFile)
        try container.encode(hasLink, forKey: .hasLink)
        try container.encode(mentionsMe, forKey: .mentionsMe)
        try container.encode(order, forKey: .order)
    }
}

/// The order hits come back in. Open, like every enum on the wire.
public enum MessageSearchOrder: Codable, Hashable, Sendable {
    case relevance
    case newest
    case unknown(String)

    init(wire: String) {
        switch wire {
        case "relevance": self = .relevance
        case "newest": self = .newest
        default: self = .unknown(wire)
        }
    }

    var wire: String {
        switch self {
        case .relevance: "relevance"
        case .newest: "newest"
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

/// One filter a backend can honor, so a client draws only the chips that
/// work (`Capabilities.messageSearchFilters`). Open.
public enum MessageSearchFilter: Codable, Hashable, Sendable {
    case from
    case conversation
    case olderThan
    case newerThan
    case hasFile
    case hasLink
    case mentionsMe
    /// `MessageSearchOrder.newest`; relevance is every backend's default.
    case newestFirst
    case unknown(String)

    init(wire: String) {
        switch wire {
        case "from": self = .from
        case "conversation": self = .conversation
        case "olderThan": self = .olderThan
        case "newerThan": self = .newerThan
        case "hasFile": self = .hasFile
        case "hasLink": self = .hasLink
        case "mentionsMe": self = .mentionsMe
        case "newestFirst": self = .newestFirst
        default: self = .unknown(wire)
        }
    }

    var wire: String {
        switch self {
        case .from: "from"
        case .conversation: "conversation"
        case .olderThan: "olderThan"
        case .newerThan: "newerThan"
        case .hasFile: "hasFile"
        case .hasLink: "hasLink"
        case .mentionsMe: "mentionsMe"
        case .newestFirst: "newestFirst"
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

/// Where the next page of a search starts. **Opaque**, like `Message.ID`: the
/// backend made it, and a client only hands it back.
public struct MessageSearchCursor: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
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

/// One page of hits. Not stored: a search's results are the person's to read,
/// and a hit that is opened arrives in the store through history.
public struct MessageSearchPage: Codable, Hashable, Sendable {
    /// In the query's order. A reply carries `isReply` and its thread, as in
    /// history.
    public var hits: [Message]
    /// The next page, or `nil` at the end.
    public var next: MessageSearchCursor?

    public init(hits: [Message] = [], next: MessageSearchCursor? = nil) {
        self.hits = hits
        self.next = next
    }
}
