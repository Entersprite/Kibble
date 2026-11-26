import Foundation

public enum PermissionAudienceDomain: Sendable {}
public typealias PermissionAudience = ConversationToken<PermissionAudienceDomain>

public extension ConversationToken where Domain == PermissionAudienceDomain {
    static let owners = Self("owners")
    static let managers = Self("managers")
    static let members = Self("members")
    static let organization = Self("organization")
    static let unknown = Self("unknown")
}

public struct ConversationPermission: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var audience: PermissionAudience
    public var isEditable: Bool
    public var allowedAudiences: [PermissionAudience]

    public init(
        id: String,
        audience: PermissionAudience,
        isEditable: Bool = false,
        allowedAudiences: [PermissionAudience] = []
    ) {
        self.allowedAudiences = allowedAudiences
        self.id = id
        self.audience = audience
        self.isEditable = isEditable
    }

    private enum CodingKeys: String, CodingKey { case id, audience, isEditable, allowedAudiences }
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.decode(String.self, forKey: .id)
        audience = try fields.decodeIfPresent(PermissionAudience.self, forKey: .audience) ?? .unknown
        allowedAudiences = try fields
            .decodeIfPresent([PermissionAudience].self, forKey: .allowedAudiences) ?? []
        isEditable = try fields.decodeIfPresent(Bool.self, forKey: .isEditable) ?? false
    }
}

public struct ConversationSettings: Codable, Hashable, Sendable {
    public var permissions: [ConversationPermission]
    public var requestToJoin: Bool?
    public var externalMembersAllowed: Bool?
    public var emoji: String?
    public var canChangeAccess: Bool
    public var canChangeRequestToJoin: Bool

    public init(
        permissions: [ConversationPermission] = [], requestToJoin: Bool? = nil,
        externalMembersAllowed: Bool? = nil, emoji: String? = nil,
        canChangeAccess: Bool = false, canChangeRequestToJoin: Bool = false
    ) {
        self.permissions = permissions
        self.requestToJoin = requestToJoin
        self.externalMembersAllowed = externalMembersAllowed
        self.emoji = emoji
        self.canChangeAccess = canChangeAccess
        self.canChangeRequestToJoin = canChangeRequestToJoin
    }

    private enum CodingKeys: String, CodingKey {
        case permissions, requestToJoin, externalMembersAllowed, emoji
        case canChangeAccess, canChangeRequestToJoin
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        permissions = try fields.decodeIfPresent([ConversationPermission].self, forKey: .permissions) ?? []
        requestToJoin = try fields.decodeIfPresent(Bool.self, forKey: .requestToJoin)
        externalMembersAllowed = try fields.decodeIfPresent(Bool.self, forKey: .externalMembersAllowed)
        emoji = try fields.decodeIfPresent(String.self, forKey: .emoji)
        canChangeAccess = try fields.decodeIfPresent(Bool.self, forKey: .canChangeAccess) ?? false
        canChangeRequestToJoin = try fields
            .decodeIfPresent(Bool.self, forKey: .canChangeRequestToJoin) ?? false
    }
}

/// Only supplied values change. An empty permissions dictionary preserves every policy.
public struct ConversationSettingsPatch: Codable, Hashable, Sendable {
    public var access: ConversationAccess?
    public var requestToJoin: Bool?
    public var permissions: [String: PermissionAudience]

    public init(
        access: ConversationAccess? = nil, requestToJoin: Bool? = nil,
        permissions: [String: PermissionAudience] = [:]
    ) {
        self.access = access
        self.requestToJoin = requestToJoin
        self.permissions = permissions
    }

    private enum CodingKeys: String, CodingKey { case access, requestToJoin, permissions }
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        access = try fields.decodeIfPresent(ConversationAccess.self, forKey: .access)
        requestToJoin = try fields.decodeIfPresent(Bool.self, forKey: .requestToJoin)
        permissions = try fields
            .decodeIfPresent([String: PermissionAudience].self, forKey: .permissions) ?? [:]
    }
}
