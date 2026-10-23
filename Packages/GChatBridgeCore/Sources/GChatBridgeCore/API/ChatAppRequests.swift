import Foundation

public enum ChatAppRequests {
    public static func search(_ query: String) throws -> BatchExecuteCall {
        var request = SearchChatAppsRequest()
        request.query = query
        request.additionalFilters = [1]
        return try BatchExecuteCall(
            rpc: "wxhTDd", payload: PBLiteEncoder.encode(request).jsonString(), sourcePath: "/app"
        )
    }

    public static func directMessage(_ id: String) -> CreateBotDmRequest {
        var request = CreateBotDmRequest()
        request.requestHeader = APIRequestHeader.make()
        request.bot.id = id; request.bot.type = .bot
        return request
    }

    public static func member(_ id: String) -> MemberId {
        var result = MemberId()
        result.userID.id = id
        result.userID.type = .bot
        return result
    }

    public static func list(_ group: GroupId, token: String?) -> ListMembersRequest {
        var request = MembersRequests.listMembers(group: group, pageToken: token)
        request.filter = 2
        return request
    }

    public static func add(_ id: String, to group: GroupId) -> CreateMembershipRequest {
        var request = CreateMembershipRequest()
        request.requestHeader = APIRequestHeader.make()
        request.groupID = group
        request.memberIds = [member(id)]
        return request
    }
}

public extension APIMethod where Request == CreateBotDmRequest, Response == CreateDmResponse {
    static var createBotDm: Self {
        Self("create_bot_dm")
    }
}
