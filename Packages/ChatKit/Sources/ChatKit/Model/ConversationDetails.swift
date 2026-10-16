import Foundation

public struct ConversationParticipant: Codable, Hashable, Sendable, Identifiable {
    public var id: Member.ID {
        member.id
    }

    public var member: Member
    public var role: ConversationRole
    public var state: ParticipantState
    /// Target-specific operations granted by the backend, independently of the role label.
    public var allowedActions: Set<String>
    public var allowedRoles: [ConversationRole]

    public init(
        member: Member,
        role: ConversationRole = .unknown,
        state: ParticipantState = .unknown,
        allowedActions: Set<String> = [],
        allowedRoles: [ConversationRole] = []
    ) {
        self.member = member
        self.role = role
        self.state = state
        self.allowedActions = allowedActions
        self.allowedRoles = allowedRoles
    }

    private enum CodingKeys: String, CodingKey { case member, role, state, allowedActions, allowedRoles }
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        member = try fields.decode(Member.self, forKey: .member)
        role = try fields.decodeIfPresent(ConversationRole.self, forKey: .role) ?? .unknown
        state = try fields.decodeIfPresent(ParticipantState.self, forKey: .state) ?? .unknown
        allowedActions = try fields.decodeIfPresent(Set<String>.self, forKey: .allowedActions) ?? []
        allowedRoles = try fields.decodeIfPresent([ConversationRole].self, forKey: .allowedRoles) ?? []
    }
}

public struct ConversationDetails: Codable, Hashable, Sendable {
    public var conversation: Conversation
    public var description: String?
    public var access: ConversationAccess
    public var membership: ParticipantState
    /// Only explicitly granted actions are offered. Missing permission never grants an edit.
    public var allowedActions: Set<String>
    public var revision: String?
    public var previewMessages: [Message]
    public var linkedGroupCount: Int?

    public init(
        conversation: Conversation,
        description: String? = nil,
        access: ConversationAccess = .unknown,
        membership: ParticipantState = .unknown,
        allowedActions: Set<String> = [],
        revision: String? = nil,
        previewMessages: [Message] = [],
        linkedGroupCount: Int? = nil
    ) {
        self.conversation = conversation
        self.description = description
        self.access = access
        self.membership = membership
        self.allowedActions = allowedActions
        self.revision = revision
        self.previewMessages = previewMessages
        self.linkedGroupCount = linkedGroupCount
    }

    private enum CodingKeys: String, CodingKey {
        case conversation, description, access, membership, allowedActions, revision, previewMessages
        case linkedGroupCount
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        conversation = try fields.decode(Conversation.self, forKey: .conversation)
        description = try fields.decodeIfPresent(String.self, forKey: .description)
        access = try fields.decodeIfPresent(ConversationAccess.self, forKey: .access) ?? .unknown
        membership = try fields.decodeIfPresent(ParticipantState.self, forKey: .membership) ?? .unknown
        allowedActions = try fields.decodeIfPresent(Set<String>.self, forKey: .allowedActions) ?? []
        revision = try fields.decodeIfPresent(String.self, forKey: .revision)
        previewMessages = try fields.decodeIfPresent([Message].self, forKey: .previewMessages) ?? []
        linkedGroupCount = try fields.decodeIfPresent(Int.self, forKey: .linkedGroupCount)
    }
}

public struct ConversationParticipantPage: Codable, Hashable, Sendable {
    public var participants: [ConversationParticipant]
    public var nextCursor: String?
    public init(participants: [ConversationParticipant], nextCursor: String? = nil) {
        self.participants = participants
        self.nextCursor = nextCursor
    }
}

public struct SpaceDirectoryQuery: Codable, Hashable, Sendable {
    public var scope: SpaceDirectoryScope
    public var text: String
    public var organization: SpaceDirectoryOrganization

    public init(
        scope: SpaceDirectoryScope = .discover, text: String = "",
        organization: SpaceDirectoryOrganization = .all
    ) {
        self.scope = scope; self.text = text; self.organization = organization
    }

    private enum CodingKeys: String, CodingKey { case scope, text, organization }
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        scope = try fields.decodeIfPresent(SpaceDirectoryScope.self, forKey: .scope) ?? .discover
        text = try fields.decodeIfPresent(String.self, forKey: .text) ?? ""
        organization = try fields
            .decodeIfPresent(SpaceDirectoryOrganization.self, forKey: .organization) ?? .all
    }
}

public struct SpaceDirectoryPage: Codable, Hashable, Sendable {
    public var spaces: [ConversationDetails]
    public var nextCursor: String?
    public init(spaces: [ConversationDetails], nextCursor: String? = nil) {
        self.spaces = spaces
        self.nextCursor = nextCursor
    }
}

public struct ConversationDraft: Codable, Hashable, Sendable {
    public var kind: Conversation.Kind
    public var name: String
    public var members: [Member.ID]
    public var description: String
    public var access: ConversationAccess

    public init(
        kind: Conversation.Kind,
        name: String = "",
        members: [Member.ID] = [],
        description: String = "",
        access: ConversationAccess = .restricted
    ) {
        self.kind = kind
        self.name = name
        self.members = members
        self.description = description
        self.access = access
    }
}

/// A confirmed creation may include failed invitations. Retrying them must not create another conversation.
public struct ConversationCreationResult: Codable, Hashable, Sendable {
    public var conversation: Conversation
    public var failedMembers: [Member.ID]
    public init(conversation: Conversation, failedMembers: [Member.ID] = []) {
        self.conversation = conversation
        self.failedMembers = failedMembers
    }
}
