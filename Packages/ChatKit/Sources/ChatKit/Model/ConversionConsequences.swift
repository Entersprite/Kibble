import Foundation

public enum ConversionTopicDomain: Sendable {}
public typealias ConversionTopic = ConversationToken<ConversionTopicDomain>

public extension ConversationToken where Domain == ConversionTopicDomain {
    static let sameConversation = Self("sameConversation")
    static let membership = Self("membership")
    static let messages = Self("messages")
    static let history = Self("history")
    static let invitations = Self("invitations")
    static let integrations = Self("integrations")
    static let externalPeople = Self("externalPeople")
    static let undo = Self("undo")
    static let unknown = Self("unknown")
}

public enum ConversionOutcomeDomain: Sendable {}
public typealias ConversionOutcome = ConversationToken<ConversionOutcomeDomain>

public extension ConversationToken where Domain == ConversionOutcomeDomain {
    static let kept = Self("kept")
    static let changed = Self("changed")
    static let notReversible = Self("notReversible")
    static let unknown = Self("unknown")
}

/// One thing converting a group chat to a space keeps, changes or cannot undo.
public struct ConversionConsequence: Codable, Hashable, Sendable {
    public var topic: ConversionTopic
    public var outcome: ConversionOutcome

    public init(topic: ConversionTopic, outcome: ConversionOutcome) {
        self.topic = topic
        self.outcome = outcome
    }

    private enum CodingKeys: String, CodingKey { case topic, outcome }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        topic = try Self.token(in: fields, for: .topic) ?? .unknown
        outcome = try Self.token(in: fields, for: .outcome) ?? .unknown
    }

    /// A missing field is unknown. A bare string is accepted as the token's type.
    private static func token<Domain>(
        in fields: KeyedDecodingContainer<CodingKeys>,
        for key: CodingKeys
    ) throws -> ConversationToken<Domain>? {
        if let bare = try? fields.decodeIfPresent(String.self, forKey: key) {
            return ConversationToken<Domain>(bare)
        }
        return try fields.decodeIfPresent(ConversationToken<Domain>.self, forKey: key)
    }
}

public struct ConversionConsequences: Codable, Hashable, Sendable {
    public var items: [ConversionConsequence]
    /// Whether the person must acknowledge the history change before converting. A missing value
    /// decodes as required, because a missing answer must land on the safe side.
    public var requiresHistoryAcknowledgement: Bool

    public init(items: [ConversionConsequence] = [], requiresHistoryAcknowledgement: Bool = true) {
        self.items = items
        self.requiresHistoryAcknowledgement = requiresHistoryAcknowledgement
    }

    private enum CodingKeys: String, CodingKey { case items, requiresHistoryAcknowledgement }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        items = try fields.decodeIfPresent([ConversionConsequence].self, forKey: .items) ?? []
        requiresHistoryAcknowledgement = try fields
            .decodeIfPresent(Bool.self, forKey: .requiresHistoryAcknowledgement) ?? true
    }
}
