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

    /// Permission-setting edit grants are explicit booleans; similarly numbered
    /// legacy capabilities describe feature availability, not edit authority.
    static func explicitGrant(_ caps: GroupScopedCapabilities, _ number: Int) -> Bool {
        ProtoFieldScan.varintValues(ofField: number, in: caps.permissions.unknownFields.data).last == 1
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

    static func actions(
        _ caps: GroupScopedCapabilities,
        joined: Bool,
        kind: Conversation.Kind? = nil
    ) -> Set<String> {
        guard joined else { return [] }
        var result = identityActions(caps, kind: kind)
        let mapped: [Int: Set<String>] = [
            14: ["addPeople"],
            21: ["addApp"],
            33: ["removeApp"],
            30: ["createWebhook", "editWebhook"],
            35: ["deleteWebhook"]
        ]
        for (number, actions) in mapped where grants(caps, number) {
            result.formUnion(actions)
        }
        if kind == .groupDirectMessage, grants(caps, 55) {
            result.insert("convertToSpace")
        }
        if kind == .space {
            result.formUnion(emailActions(caps))
        }
        return result
    }

    private static func identityActions(
        _ caps: GroupScopedCapabilities,
        kind: Conversation.Kind?
    ) -> Set<String> {
        let legacy = Set(caps.capabilities + caps.permissions.capabilities)
        var result = Set<String>()
        if legacy.contains(6) {
            result.insert("rename")
        }
        if legacy.contains(8) {
            result.insert("description")
            if kind == .space {
                result.insert("guidelines")
            }
        }
        if !result.isEmpty {
            result.formUnion(["identity", "details"])
        }
        return result
    }

    private static func emailActions(_ caps: GroupScopedCapabilities) -> Set<String> {
        let legacy = Set(caps.capabilities + caps.permissions.capabilities)
        var result = Set<String>()
        if legacy.contains(46) {
            result.insert("generateEmail")
        }
        if legacy.contains(48) {
            result.insert("setEmailDelivery")
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
        if fallback == nil || fallback?.kind == .groupDirectMessage && group.hasAttributeCheckerGroupType
            && [.flatRoom, .threadedRoom, .postRoom].contains(group.attributeCheckerGroupType) {
            result.kind = initialKind(group)
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
        if result.kind != .meetChat {
            result.meeting = nil
        } else if !group.spaceIntegrationPayloads.isEmpty {
            result.meeting = MeetingMapping.occurrence(in: group.spaceIntegrationPayloads)
        }
        return result
    }

    private static func initialKind(_ group: Group) -> Conversation.Kind {
        if let raw = ProtoFieldScan.varintValues(ofField: 33, in: group.unknownFields.data).last {
            return .unknown("\(WorldMapping.groupTypeTokenPrefix)\(raw)")
        }
        guard group.hasAttributeCheckerGroupType else { return .unknown("provider") }
        switch group.attributeCheckerGroupType {
        case .immutableMembershipGroupDm: return .groupDirectMessage
        case .flatRoom, .threadedRoom, .postRoom: return .space
        case .meetingChat: return .meetChat
        default: return .unknown("provider")
        }
    }

    static func participant(
        _ row: Membership,
        group: GroupId,
        me: ChatKit.Member.ID,
        people: [ChatKit.Member.ID: ChatKit.Member],
        caps: GroupScopedCapabilities,
        viewerIsOwner: Bool = false, selfRoleChange: Bool = false,
        isExternal: Bool? = nil, isBlocked: Bool? = nil, canBlock: Bool = false
    )
        -> ConversationParticipant? {
        guard belongs(row, to: group) else { return nil }
        let user = ChatKit.Member.ID(row.id.memberID.userID.id)
        guard !user.rawValue.isEmpty, row.id.memberID.userID.type == .human else { return nil }
        let other = user != me
        var actions = participantMembershipActions(
            row,
            other: other,
            caps: caps,
            viewerIsOwner: viewerIsOwner
        )
        let roles = participantRoles(
            row,
            caps: caps,
            viewerIsOwner: viewerIsOwner,
            mayChange: other || selfRoleChange
        )
        if !roles.isEmpty {
            actions.insert("setRole")
        }
        if canBlock, other, [.memberJoined, .memberInvited].contains(row.membershipState) {
            actions.insert(isBlocked == true ? "unblockPerson" : "blockPerson")
        }
        return ConversationParticipant(
            member: people[user] ?? ChatKit.Member(id: user, kind: .human),
            role: ManagementMapping.role(in: row),
            state: ManagementMapping.state(row.membershipState, unknown: row.unknownFields.data),
            allowedActions: actions,
            allowedRoles: roles, isExternal: isExternal, isBlocked: isBlocked
        )
    }

    private static func participantMembershipActions(
        _ row: Membership,
        other: Bool,
        caps: GroupScopedCapabilities,
        viewerIsOwner: Bool
    ) -> Set<String> {
        guard other else { return [] }
        var actions = Set<String>()
        if row.membershipState.rawValue == 6 {
            if grants(caps, 14) {
                actions.insert("approveRequest")
            }
            if grants(caps, 4) {
                actions.insert("rejectRequest")
            }
        }
        let role = role(in: row)
        if [.memberJoined, .memberInvited].contains(row.membershipState), grants(caps, 4),
           [.member, .manager, .owner].contains(role), role != .owner || viewerIsOwner {
            actions.insert("removePerson")
        }
        return actions
    }

    private static func participantRoles(
        _ row: Membership,
        caps: GroupScopedCapabilities,
        viewerIsOwner: Bool,
        mayChange: Bool
    ) -> [ConversationRole] {
        guard mayChange, row.membershipState == .memberJoined,
              [.member, .manager, .owner].contains(role(in: row)) else { return [] }
        var roles: [ConversationRole] = []
        if row.membershipRole == .roleMember, grants(caps, 2) {
            roles = [.member, .manager]
        }
        if row.membershipRole == .roleManager, grants(caps, 60) {
            roles = [.member, .manager]
        }
        if viewerIsOwner, grants(caps, 2),
           [.roleMember, .roleManager, .roleOwner].contains(row.membershipRole) {
            if !roles.contains(.member) {
                roles.append(.member)
            }
            if !roles.contains(.owner) {
                roles.append(.owner)
            }
            if grants(caps, 60), !roles.contains(.manager) {
                roles.append(.manager)
            }
        }
        return roles
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
            previewMessages: preview?.conversationID == conversation.id ? preview.map { [$0] } ?? [] : [],
            guidelines: response.group.hasGroupDetails ? response.group.groupDetails.guidelines : nil,
            fieldLimits: ["name": 128, "description": 150, "guidelines": 5000]
        )
    }

    static func adoptMembers(_ response: GetGroupResponse, into conversation: inout Conversation) {
        guard conversation.kind == .groupDirectMessage, !response.joinedMemberIds.isEmpty else { return }
        conversation.members = response.joinedMemberIds.compactMap {
            $0.userID.id.isEmpty ? nil : ChatKit.Member.ID($0.userID.id)
        }
        conversation.memberCount = conversation.members.count
    }

    static func belongs(_ row: Membership, to group: GroupId) -> Bool {
        if row.id.hasGroupID {
            return row.id.groupID == group
        }
        if case let .spaceID(space) = group.id {
            return row.id.hasSpaceID && row.id.spaceID == space
        }
        return false
    }
}
