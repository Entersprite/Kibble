import ChatKit
import Foundation
import GChatBridgeCore

/// Provider-only translation. Permissions are explicit grants, never inferred from a role.
enum ManagementMapping {
    static func state(_ value: MembershipState, unknown: Data = Data(), field: Int = 3) -> ParticipantState {
        if let raw = ProtoFieldScan.varintValues(ofField: field, in: unknown).last {
            return ParticipantState("provider:\(raw)")
        }
        switch value {
        case .memberJoined: return .joined
        case .memberInvited: return .invited
        case .memberRequested: return .requested
        default: return ParticipantState("provider:\(value.rawValue)")
        }
    }

    static func role(_ value: MembershipRole) -> ConversationRole {
        switch value {
        case .roleOwner: .owner
        case .roleManager: .manager
        case .roleMember: .member
        default: ConversationRole("provider:\(value.rawValue)")
        }
    }

    static func role(in row: Membership) -> ConversationRole {
        if let value = ProtoFieldScan.varintValues(ofField: 5, in: row.unknownFields.data).last {
            return ConversationRole("provider:\(value)")
        }
        return role(row.membershipRole)
    }

    static func role(_ value: ConversationRole) -> MembershipRole? {
        switch value {
        case .owner: .roleOwner
        case .manager: .roleManager
        case .member: .roleMember
        default: nil
        }
    }

    static func grants(_ caps: GroupScopedCapabilities, _ number: Int) -> Bool {
        // New permission booleans take precedence, including an explicit refusal.
        let values = ProtoFieldScan.varintValues(ofField: number, in: caps.permissions.unknownFields.data)
        if let value = values.last {
            return value == 1
        }
        return caps.capabilities.contains(Int32(number)) || caps.permissions.capabilities
            .contains(Int32(number))
    }

    static func actions(_ caps: GroupScopedCapabilities, joined: Bool) -> Set<String> {
        guard joined else { return [] }
        var result = Set<String>()
        // Legacy capability enum values used by the web edit-details dialog.
        let legacy = Set(caps.capabilities + caps.permissions.capabilities)
        if legacy.contains(6) {
            result.insert("rename")
        }
        if legacy.contains(8) {
            result.insert("description")
        }
        if !result.isEmpty {
            result.insert("identity")
        }
        if grants(caps, 54) {
            result.insert("addPeople")
        }
        return result
    }

    static func canDeleteSpace(_ caps: GroupScopedCapabilities) -> Bool {
        // Web ztr: explicit permission 3 overrides the legacy DELETE_GROUP capability 2.
        if let value = ProtoFieldScan.varintValues(ofField: 3, in: caps.permissions.unknownFields.data).last {
            return value == 1
        }
        return (caps.capabilities + caps.permissions.capabilities).contains(2)
    }

    static func conversation(_ group: Group, fallback: Conversation? = nil) -> Conversation? {
        guard let id = ChannelEventMapping.conversationID(group.groupID) else { return nil }
        var result = fallback ?? Conversation(id: id, kind: .unknown("provider"))
        result.title = group.hasName ? group.name : result.title
        if fallback == nil {
            let unknownType = ProtoFieldScan.varintValues(ofField: 33, in: group.unknownFields.data).last
            if let unknownType {
                result.kind = unknownType == 10 ? .meetChat :
                    .unknown("\(WorldMapping.groupTypeTokenPrefix)\(unknownType)")
            } else if group.hasAttributeCheckerGroupType {
                switch group.attributeCheckerGroupType {
                case .immutableMembershipGroupDm: result.kind = .groupDirectMessage
                case .flatRoom, .threadedRoom, .postRoom: result.kind = .space
                default: break
                }
            }
        }
        if group.hasAvatarURL {
            result.avatarURL = URL(string: group.avatarURL)
        }
        if group.sortTime > 0 {
            result.lastActivity = Microseconds.date(group.sortTime)
        }
        if case .threadedGroup = group.threadedModel {
            result.isThreaded = true
        }
        return result
    }

    static func participant(
        _ row: Membership,
        group: GroupId,
        me: ChatKit.Member.ID,
        people: [ChatKit.Member.ID: ChatKit.Member],
        caps: GroupScopedCapabilities
    )
        -> ConversationParticipant? {
        guard belongs(row, to: group) else { return nil }
        let user = ChatKit.Member.ID(row.id.memberID.userID.id)
        guard !user.rawValue.isEmpty else { return nil }
        var actions = Set<String>()
        var roles: [ConversationRole] = []
        if user != me, row.membershipState.rawValue == 6 {
            if grants(caps, 54) {
                actions.insert("approveRequest")
            }
            if grants(caps, 4) {
                actions.insert("rejectRequest")
            }
        }
        if user != me, row.membershipState == .memberJoined {
            if ManagementMapping.grants(caps, 4),
               row.membershipRole != .roleOwner {
                actions.insert("removePerson")
            }
            if ManagementMapping.grants(caps, 2), row.membershipRole == .roleMember {
                roles = [.member, .manager]
            }
            if ManagementMapping.grants(caps, 60), row.membershipRole == .roleManager {
                roles = [.member, .manager]
            }
            if !roles.isEmpty {
                actions.insert("setRole")
            }
        }
        return ConversationParticipant(
            member: people[user] ?? ChatKit.Member(id: user, kind: .human),
            role: ManagementMapping.role(in: row),
            state: ManagementMapping.state(row.membershipState, unknown: row.unknownFields.data),
            allowedActions: actions,
            allowedRoles: roles
        )
    }

    static func details(
        _ response: GetGroupResponse,
        conversation: Conversation,
        membership: ParticipantState,
        actions: Set<String>
    ) -> ConversationDetails {
        let preview = response.hasSnippet ? ChannelEventMapping.domainMessage(response.snippet) : nil
        return ConversationDetails(
            conversation: conversation,
            description: response.group.hasGroupDetails ? response.group.groupDetails
                .description_p : nil,
            membership: membership,
            allowedActions: actions,
            revision: response.group
                .hasRevisionTime ? String(response.group.revisionTime) : nil,
            previewMessages: preview?.conversationID == conversation.id ? preview.map { [$0] } ?? [] : []
        )
    }

    static func adoptMembers(_ response: GetGroupResponse, into conversation: inout Conversation) {
        guard conversation.kind == .groupDirectMessage, !response.joinedMemberIds.isEmpty else { return }
        conversation.members = response.joinedMemberIds.compactMap {
            $0.userID.id.isEmpty ? nil : ChatKit.Member.ID($0.userID.id)
        }
        conversation.memberCount = conversation.members.count
    }

    private static func belongs(_ row: Membership, to group: GroupId) -> Bool {
        if row.id.hasGroupID {
            return row.id.groupID == group
        }
        if case let .spaceID(space) = group.id {
            return row.id.hasSpaceID && row.id.spaceID == space
        }
        return false
    }
}
