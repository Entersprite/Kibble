import Foundation

/// Sidebar actions from Chat's web client. The RPC group reference differs
/// from the protobuf GroupId: [prefixed id, raw id, kind (space 2, DM 5)].
/// Request shapes are source-derived; live verification is still required.
public enum ConversationActionRequests {
    public static func unread(group: GroupId, micros: Int64) -> SetMarkAsUnreadTimestampRequest {
        var request = SetMarkAsUnreadTimestampRequest()
        request.requestHeader = APIRequestHeader.make()
        request.groupID = group
        request.unreadTimestamp = micros
        return request
    }

    public static func clearHistory(group: GroupId, micros: Int64) throws -> BatchExecuteCall {
        try rpc("azPJGe", group: group, value: micros)
    }

    private static func rpc(_ name: String, group: GroupId, value: Any) throws -> BatchExecuteCall {
        let reference: [Any]
        switch group.id {
        case let .dmID(id): reference = ["dm/" + id.dmID, id.dmID, 5]
        case let .spaceID(id): reference = ["space/" + id.spaceID, id.spaceID, 2]
        case nil: throw ConversationActionRequestError.missingGroup
        }
        let data = try JSONSerialization.data(
            withJSONObject: [reference, value],
            options: [.withoutEscapingSlashes]
        )
        return BatchExecuteCall(rpc: name, payload: String(decoding: data, as: UTF8.self), sourcePath: "/app")
    }

    public static func hide(group: GroupId, hidden: Bool = true) -> HideGroupRequest {
        var request = HideGroupRequest()
        request.requestHeader = APIRequestHeader.make()
        request.id = group
        request.hide = hidden
        return request
    }

    /// DMs block the other person; spaces and group chats block their group.
    public static func block(group: GroupId, user: UserId?) -> BlockEntityRequest {
        var request = BlockEntityRequest()
        request.requestHeader = APIRequestHeader.make()
        if let user {
            request.userID = user
        } else {
            request.groupID = group
        }
        request.blocked = true
        request.reported = false
        return request
    }

    public static func leave(group: GroupId, member: MemberId) -> RemoveMembershipsRequest {
        var request = RemoveMembershipsRequest()
        request.requestHeader = APIRequestHeader.make()
        request.groupID = group
        request.memberIds = [member]
        return request
    }
}

public enum ConversationActionRequestError: Error { case missingGroup }

public extension APIMethod where Request == HideGroupRequest, Response == HideGroupResponse {
    static var hideGroup: Self {
        Self("hide_group")
    }
}

public extension APIMethod where Request == BlockEntityRequest, Response == BlockEntityResponse {
    static var blockEntity: Self {
        Self("block_entity")
    }
}

public extension APIMethod where Request == RemoveMembershipsRequest, Response == RemoveMembershipsResponse {
    static var removeMemberships: Self {
        Self("remove_memberships")
    }
}

public extension APIMethod where Request == SetMarkAsUnreadTimestampRequest,
    Response == SetMarkAsUnreadTimestampResponse {
    static var setMarkAsUnreadTimestamp: Self {
        Self("set_mark_as_unread_timestamp")
    }
}
