import Foundation

public extension APIMethod where Request == CatchUpUserRequest, Response == CatchUpResponse {
    static var catchUpUser: Self {
        Self("catch_up_user")
    }
}

public extension APIMethod where Request == CatchUpGroupRequest, Response == CatchUpResponse {
    static var catchUpGroup: Self {
        Self("catch_up_group")
    }
}

/// Read-only revision recovery requests. Revisions stay inside the provider.
public enum CatchUpRequests {
    public static func user(from: Int64, through: Int64, pageSize: Int32 = 100) -> CatchUpUserRequest {
        var request = CatchUpUserRequest()
        request.requestHeader = APIRequestHeader.make()
        request.range = range(from: from, through: through)
        request.pageSize = pageSize
        request.cutoffSize = 1000
        return request
    }

    public static func group(
        _ group: GroupId, from: Int64, through: Int64, pageSize: Int32 = 100
    ) -> CatchUpGroupRequest {
        var request = CatchUpGroupRequest()
        request.requestHeader = APIRequestHeader.make()
        request.groupID = group
        request.range = range(from: from, through: through)
        request.pageSize = pageSize
        request.cutoffSize = 1000
        return request
    }

    private static func range(from: Int64, through: Int64) -> CatchUpRange {
        var range = CatchUpRange()
        range.fromRevisionTimestamp = from
        range.toRevisionTimestamp = through
        return range
    }
}
