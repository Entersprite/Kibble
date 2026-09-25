import Foundation

/// Which level a record belongs to. `{"type": …}` discriminated, hand-coded,
/// and an unknown scope is kept verbatim (spec §2.2).
public enum SettingsScope: Hashable, Sendable {
    case global
    case section(SectionKey)
    case conversation(Conversation.ID)
    case keywords
    case pause
    case unknown(type: String, payload: JSONValue)
}

/// What a record holds.
public enum SettingsValue: Hashable, Sendable {
    case rule(NotificationRule)
    case keywords([String])
    case pause(Pause)
    case unknown(type: String, payload: JSONValue)
}

/// Whether notifications are paused. Explicit rather than an optional date,
/// which could not tell "not paused" from "until I resume".
public enum Pause: Hashable, Sendable {
    case off
    case until(Date)
    case untilResumed
    case unknown(type: String, payload: JSONValue)
}

// MARK: - NotificationSettings

extension NotificationSettings: Codable {
    enum CodingKeys: String, CodingKey {
        case schemaVersion, records
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            records: container.decodeIfPresent([SettingsRecord].self, forKey: .records) ?? [],
            schemaVersion: container.decodeIfPresent(Int.self, forKey: .schemaVersion)
                ?? Self.currentSchemaVersion
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(records, forKey: .records)
    }
}

// MARK: - SettingsRecord

extension SettingsRecord: Codable {
    enum CodingKeys: String, CodingKey {
        case scope, value, modifiedAt, modifiedBy
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            scope: container.decode(SettingsScope.self, forKey: .scope),
            value: container.decode(SettingsValue.self, forKey: .value),
            modifiedAt: container.decodeWire(Date.self, forKey: .modifiedAt),
            modifiedBy: container.decode(String.self, forKey: .modifiedBy)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(scope, forKey: .scope)
        try container.encode(value, forKey: .value)
        try container.encodeWire(modifiedAt, forKey: .modifiedAt)
        try container.encode(modifiedBy, forKey: .modifiedBy)
    }
}

// MARK: - SettingsScope

extension SettingsScope: Codable {
    enum CodingKeys: String, CodingKey {
        case type, section, conversationID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "global": self = .global
        case "section": self = try .section(container.decode(SectionKey.self, forKey: .section))
        case "conversation":
            self = try .conversation(container.decode(Conversation.ID.self, forKey: .conversationID))
        case "keywords": self = .keywords
        case "pause": self = .pause
        default: self = try .unknown(type: type, payload: UnknownFrame.payload(from: decoder))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        if case let .unknown(type, payload) = self {
            try UnknownFrame.encode(type: type, payload: payload, to: encoder)
            return
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .global:
            try container.encode("global", forKey: .type)
        case let .section(section):
            try container.encode("section", forKey: .type)
            try container.encode(section, forKey: .section)
        case let .conversation(id):
            try container.encode("conversation", forKey: .type)
            try container.encode(id, forKey: .conversationID)
        case .keywords:
            try container.encode("keywords", forKey: .type)
        case .pause:
            try container.encode("pause", forKey: .type)
        case .unknown:
            throw WireEncoding.unhandled(self, path: container.codingPath)
        }
    }
}

// MARK: - SettingsValue

extension SettingsValue: Codable {
    enum CodingKeys: String, CodingKey {
        case type, rule, words, pause
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "rule": self = try .rule(container.decode(NotificationRule.self, forKey: .rule))
        case "keywords": self = try .keywords(container.decode([String].self, forKey: .words))
        case "pause": self = try .pause(container.decode(Pause.self, forKey: .pause))
        default: self = try .unknown(type: type, payload: UnknownFrame.payload(from: decoder))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        if case let .unknown(type, payload) = self {
            try UnknownFrame.encode(type: type, payload: payload, to: encoder)
            return
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .rule(rule):
            try container.encode("rule", forKey: .type)
            try container.encode(rule, forKey: .rule)
        case let .keywords(words):
            try container.encode("keywords", forKey: .type)
            try container.encode(words, forKey: .words)
        case let .pause(pause):
            try container.encode("pause", forKey: .type)
            try container.encode(pause, forKey: .pause)
        case .unknown:
            throw WireEncoding.unhandled(self, path: container.codingPath)
        }
    }
}

// MARK: - Pause

extension Pause: Codable {
    enum CodingKeys: String, CodingKey {
        case type, date
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "off": self = .off
        case "until": self = try .until(container.decodeWire(Date.self, forKey: .date))
        case "untilResumed": self = .untilResumed
        default: self = try .unknown(type: type, payload: UnknownFrame.payload(from: decoder))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        if case let .unknown(type, payload) = self {
            try UnknownFrame.encode(type: type, payload: payload, to: encoder)
            return
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .off:
            try container.encode("off", forKey: .type)
        case let .until(date):
            try container.encode("until", forKey: .type)
            try container.encodeWire(date, forKey: .date)
        case .untilResumed:
            try container.encode("untilResumed", forKey: .type)
        case .unknown:
            throw WireEncoding.unhandled(self, path: container.codingPath)
        }
    }
}
