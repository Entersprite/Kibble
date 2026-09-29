import Foundation

/// A participant: a person, or an app.
///
/// `displayName` is optional because it genuinely is. Under user
/// authentication the Chat API returns only a name and a type for an app, and
/// the People API has no profile for one — an app is not a Google account. See
/// `DisplayNameResolution` for what a client shows instead.
public struct Member: Codable, Hashable, Sendable {
    public var id: ID
    public var kind: Kind
    public var displayName: String?
    public var email: String?
    public var avatarURL: URL?

    /// `nil` and `.unknown` mean different things and both are needed. `nil` is
    /// "nobody has told us"; `.unknown(raw)` is "we were told something this
    /// build does not understand". Collapsing them would lose the difference
    /// between a backend that does not report presence and one that reports a
    /// state we have never seen.
    public var presence: Presence?

    /// A claim about now, like `presence`: `nil` is "nobody told us", and a
    /// status that has been cleared arrives as `.statusChanged` with `nil`.
    public var status: MemberStatus?

    public init(
        id: ID,
        kind: Kind,
        displayName: String? = nil,
        email: String? = nil,
        avatarURL: URL? = nil,
        presence: Presence? = nil,
        status: MemberStatus? = nil
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.email = email
        self.avatarURL = avatarURL
        self.presence = presence
        self.status = status
    }
}

// MARK: - Identifier

public extension Member {
    /// A member identifier. Opaque: a client compares and stores it, and never
    /// takes it apart.
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

public extension Member {
    /// Human or app. Open, so a third kind arriving later degrades to
    /// `.unknown` rather than failing the frame.
    enum Kind: Codable, Hashable, Sendable {
        case human
        case app
        case unknown(String)

        init(wire: String) {
            switch wire {
            case "human": self = .human
            case "app": self = .app
            default: self = .unknown(wire)
            }
        }

        var wire: String {
            switch self {
            case .human: "human"
            case .app: "app"
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

public extension Member {
    internal enum CodingKeys: String, CodingKey {
        case id
        case kind
        case displayName
        case email
        case avatarURL
        case presence
        case status
    }

    /// Hand-written for the same reason as `Conversation`: `id` and `kind` are
    /// required, and the optionals are omitted rather than written as `null`.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(ID.self, forKey: .id),
            kind: container.decode(Kind.self, forKey: .kind),
            displayName: container.decodeIfPresent(String.self, forKey: .displayName),
            email: container.decodeIfPresent(String.self, forKey: .email),
            avatarURL: container.decodeIfPresent(URL.self, forKey: .avatarURL),
            presence: container.decodeIfPresent(Presence.self, forKey: .presence),
            status: container.decodeIfPresent(MemberStatus.self, forKey: .status)
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(displayName, forKey: .displayName)
        try container.encodeIfPresent(email, forKey: .email)
        try container.encodeIfPresent(avatarURL, forKey: .avatarURL)
        try container.encodeIfPresent(presence, forKey: .presence)
        try container.encodeIfPresent(status, forKey: .status)
    }
}
