import Foundation

/// The local user's own setting: shown as available, shown as away, or not
/// to be disturbed until a time (set-your-status spec §2). A setting, not
/// what others see: "away" turns presence sharing off, which from outside
/// looks the same as being idle.
///
/// Open, like every enum on the wire: a state a newer backend knows decodes
/// to `.unknown` and checks nothing in the menu.
public enum Availability: Codable, Hashable, Sendable {
    case automatic
    case away
    case doNotDisturb(until: Date)
    case unknown(String)
}

public extension Availability {
    internal enum CodingKeys: String, CodingKey {
        case type
        case until
    }

    internal enum Tag: String {
        case automatic
        case away
        case doNotDisturb
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .type)
        switch Tag(rawValue: raw) {
        case .automatic:
            self = .automatic
        case .away:
            self = .away
        case .doNotDisturb:
            self = try .doNotDisturb(until: container.decodeWire(Date.self, forKey: .until))
        case nil:
            self = .unknown(raw)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .automatic:
            try container.encode(Tag.automatic.rawValue, forKey: .type)
        case .away:
            try container.encode(Tag.away.rawValue, forKey: .type)
        case let .doNotDisturb(until):
            try container.encode(Tag.doNotDisturb.rawValue, forKey: .type)
            try container.encodeWire(until, forKey: .until)
        case let .unknown(raw):
            try container.encode(raw, forKey: .type)
        }
    }
}
