import Foundation

/// An extensible discriminator retaining every field from an unfamiliar peer.
public struct ConversationToken<Domain: Sendable>: Codable, Hashable, Sendable {
    private let payload: JSONValue

    public init(_ type: String) {
        payload = .object(["type": .string(type)])
    }

    public var type: String {
        guard case let .object(fields) = payload, case let .string(type) = fields["type"] else { return "" }
        return type
    }

    public init(from decoder: any Decoder) throws {
        let value = try JSONValue(from: decoder)
        guard case let .object(fields) = value, case .string = fields["type"] else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Expected a type discriminator."
            ))
        }
        payload = value
    }

    public func encode(to encoder: any Encoder) throws {
        try payload.encode(to: encoder)
    }
}

public enum ConversationRoleDomain: Sendable {}
public enum ParticipantStateDomain: Sendable {}
public enum SpaceScopeDomain: Sendable {}
public enum SpaceOrganizationDomain: Sendable {}
public enum ConversationAccessDomain: Sendable {}
public typealias ConversationRole = ConversationToken<ConversationRoleDomain>
public typealias ParticipantState = ConversationToken<ParticipantStateDomain>
public typealias SpaceDirectoryScope = ConversationToken<SpaceScopeDomain>
public typealias SpaceDirectoryOrganization = ConversationToken<SpaceOrganizationDomain>
public typealias ConversationAccess = ConversationToken<ConversationAccessDomain>

public extension ConversationToken where Domain == ConversationRoleDomain {
    static let member = Self("member")
    static let manager = Self("manager")
    static let owner = Self("owner")
    static let unknown = Self("unknown")
}

public extension ConversationToken where Domain == ParticipantStateDomain {
    static let joined = Self("joined")
    static let invited = Self("invited")
    static let requested = Self("requested")
    static let unknown = Self("unknown")
}

public extension ConversationToken where Domain == SpaceScopeDomain {
    static let joined = Self("joined")
    static let discover = Self("discover")
    static let all = Self("all")
    static let spamInvitations = Self("spamInvitations")
    static let invitations = Self("invitations")
}

public extension ConversationToken where Domain == ConversationAccessDomain {
    static let restricted = Self("restricted")
    static let discoverable = Self("discoverable")
    static let open = Self("open")
    static let unknown = Self("unknown")
}

public extension ConversationToken where Domain == SpaceOrganizationDomain {
    static let all = Self("all")
    static let internalOnly = Self("internal")
    static let externalOnly = Self("external")
}
