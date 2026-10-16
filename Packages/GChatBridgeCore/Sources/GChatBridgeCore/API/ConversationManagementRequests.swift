import Foundation

/// Management requests use the same account-scoped API header as ordinary chat.
public enum ConversationManagementRequests {
    public static func membershipID(group: GroupId, user: String) -> MembershipId {
        var id = MembershipId()
        var person = UserId(); person.id = user
        var member = MemberId(); member.userID = person
        id.memberID = member; id.groupID = group
        return id
    }

    public static func details(_ group: GroupId) -> GetGroupRequest {
        var request = GetGroupRequest()
        request.requestHeader = APIRequestHeader.make(); request.groupID = group
        request.fetchOptions = [
            .members,
            .invitees,
            .includeDynamicGroupName,
            .includeAccountUserCapabilities
        ]
        request.includeInviteDms = true
        return request
    }

    public static func permissions(_ id: MembershipId) -> GetGroupScopedCapabilitiesRequest {
        var request = GetGroupScopedCapabilitiesRequest()
        request.requestHeader = APIRequestHeader.make(); request.membershipIds = [id]
        return request
    }

    public static func create(
        name: String,
        description: String,
        people: [String],
        space: Bool,
        localID: String
    ) -> CreateGroupRequest {
        var info = SpaceCreationInfo()
        if !name.isEmpty {
            info.name = name
        }
        info.attributeCheckerGroupType = space ? .flatRoom : .immutableMembershipGroupDm
        if !description.isEmpty {
            info.spaceDetails.description_p = description
        }
        info.inviteeMemberInfos = people.map { id in
            var user = UserId(); user.id = id
            var invitee = InviteeInfo(); invitee.userID = user
            var member = InviteeMemberInfo(); member.inviteeInfo = invitee
            return member
        }
        var request = CreateGroupRequest()
        request.requestHeader = APIRequestHeader.make(); request.space = info
        request.localID = localID; request.shouldFindExistingSpace = false
        return request
    }

    public static func identity(_ group: GroupId, name: String?, description: String?) -> UpdateGroupRequest {
        var request = UpdateGroupRequest()
        request.requestHeader = APIRequestHeader.make(); request.groupID = group
        if let name {
            request.name = name; request.updateMasks.append(.name)
        }
        if let description {
            request.spaceDetails.description_p = description; request.updateMasks.append(.spaceDetails)
        }
        return request
    }

    public static func add(
        _ people: [String],
        group: GroupId,
        join: Bool = false,
        requestJoin: Bool = false
    ) -> CreateMembershipRequest {
        var request = CreateMembershipRequest()
        request.requestHeader = APIRequestHeader.make(); request.groupID = group
        request.memberIds = people.map { membershipID(group: group, user: $0).memberID }
        if join {
            request.membershipState = .memberJoined
        }
        if requestJoin {
            request.requestToJoin = true
        }
        return request
    }

    public static func role(
        _ role: MembershipRole,
        user: String,
        group: GroupId
    ) -> UpdateMembershipRoleRequest {
        var change = UpdateMembershipRoleRequest.Change()
        change.userID.id = user; change.groupID = group; change.role = role
        var request = UpdateMembershipRoleRequest()
        request.requestHeader = APIRequestHeader.make(); request.changes = [change]
        return request
    }

    public enum DirectoryMembership: Sendable { case all, joined, notJoined }
    public enum DirectoryOrganization: Sendable { case all, internalOnly, externalOnly }

    public static func discover(
        _ text: String, token: String?, membership: DirectoryMembership = .notJoined,
        organization: DirectoryOrganization = .all
    ) -> SearchSpaceDirectoryRequest {
        var request = SearchSpaceDirectoryRequest()
        request.requestHeader = APIRequestHeader.make(); request.pageSize = 50
        request.query = text; request.searchAll = false
        request.directoryMode = 1; request.context = ""
        let terms: [(Int32, Int32)] = switch membership {
        case .all: []
        case .joined: [(1, 0)]
        case .notJoined: [(3, 2), (2, 0)]
        }
        request.filter.membership = SearchSpaceDirectoryRequest.MembershipFilter()
        request.filter.membership.criteria = terms.map { type, value in
            var criterion = SearchSpaceDirectoryRequest.MembershipCriterion()
            criterion.type = type; criterion.value = value
            return criterion
        }
        switch organization {
        case .all: request.filter.organization = 0
        case .internalOnly: request.filter.organization = 2
        case .externalOnly: request.filter.organization = 1
        }
        if let token {
            request.pageToken = token
        }
        return request
    }

    public static func invitations(spam: Bool = false) -> ListInvitedRoomsRequest {
        var request = ListInvitedRoomsRequest(); request.requestHeader = APIRequestHeader.make()
        request.inviteCategory = spam ? .spamInvite : .regularInvite
        return request
    }

    public static func deleteSpace(_ group: GroupId) -> DeleteGroupV2Request {
        var request = DeleteGroupV2Request()
        request.requestHeader = APIRequestHeader.make(); request.groupID = group
        // The web dialog passes false for "Delete the space only"; ui negates it in field 2.
        request.preserveLinkedGroup = true
        return request
    }
}

public extension APIMethod where Request == DeleteGroupV2Request, Response == DeleteGroupV2Response {
    static var deleteGroupV2: Self {
        Self("delete_group_v2", allowsEmptyResponse: true)
    }
}

public extension APIMethod where Request == GetGroupRequest, Response == GetGroupResponse {
    static var managementDetails: Self {
        Self("get_group")
    }
}

public extension APIMethod where Request == GetGroupScopedCapabilitiesRequest,
    Response == GetGroupScopedCapabilitiesResponse {
    static var managementPermissions: Self {
        Self("get_group_scoped_capabilities")
    }
}

public extension APIMethod where Request == CreateGroupRequest, Response == CreateGroupResponse {
    static var createGroup: Self {
        Self("create_group")
    }
}

public extension APIMethod where Request == UpdateGroupRequest, Response == UpdateGroupResponse {
    static var updateGroup: Self {
        Self("update_group")
    }
}

public extension APIMethod where Request == CreateMembershipRequest, Response == CreateMembershipResponse {
    static var createMembership: Self {
        Self("create_membership")
    }
}

public extension APIMethod where Request == UpdateMembershipRoleRequest,
    Response == UpdateMembershipRoleResponse {
    static var updateMembershipRole: Self {
        Self("update_membership_role")
    }
}

public extension APIMethod where Request == SearchSpaceDirectoryRequest,
    Response == SearchSpaceDirectoryResponse {
    static var searchSpaceDirectory: Self {
        Self("search_space_directory")
    }
}

public extension APIMethod where Request == ListInvitedRoomsRequest, Response == ListInvitedRoomsResponse {
    static var listInvitedRooms: Self {
        Self("list_invited_rooms")
    }
}
