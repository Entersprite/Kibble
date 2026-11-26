import Foundation

/// Who manages a connected account, as its provider states it: what tells two
/// accounts of the same person apart ("Managed by example.test").
///
/// Display metadata only. It is never an authorization fact, and nothing may
/// be inferred from it about what the account can reach.
///
/// `{"type": …}` discriminated and hand-coded; an unknown type is kept
/// verbatim, the same contract as `Mention.Target`.
public enum AccountOrganization: Codable, Hashable, Sendable {
    /// Administered by an organization; `domain` is what the provider shows for it.
    case managed(domain: String)
    /// A consumer account that no organization manages.
    case personal
    /// The provider has not said. The default for every provider that does not
    /// adopt `AccountOrganizationBackend`.
    case unstated
    case unknown(type: String, payload: JSONValue)
}

public extension AccountOrganization {
    private enum CodingKeys: String, CodingKey {
        case type, domain
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "managed": self = try .managed(domain: container.decode(String.self, forKey: .domain))
        case "personal": self = .personal
        case "unstated": self = .unstated
        default: self = try .unknown(type: type, payload: UnknownFrame.payload(from: decoder))
        }
    }

    func encode(to encoder: any Encoder) throws {
        if case let .unknown(type, payload) = self {
            try UnknownFrame.encode(type: type, payload: payload, to: encoder)
            return
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .managed(domain):
            try container.encode("managed", forKey: .type)
            try container.encode(domain, forKey: .domain)
        case .personal:
            try container.encode("personal", forKey: .type)
        case .unstated:
            try container.encode("unstated", forKey: .type)
        case .unknown:
            throw WireEncoding.unhandled(self, path: container.codingPath)
        }
    }
}
