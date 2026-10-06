import Foundation

/// `list_members`: a space's full membership, by id (`findings.md` §56.1).
///
/// The shape is the web client's, seen in the owner's capture: `group_id`,
/// `fetch_options` `[4, 5]`, `filter` `1`, and no `page_size`. Neither
/// reference calls `list_members`; Chat on the web calls it for every space it
/// loads. The answer carries membership rows only, so names still come from
/// `get_members`. `[Verify]` until one probe run sends it from here.
public enum MembersRequests {
    public static func listMembers(group: GroupId, pageToken: String?) -> ListMembersRequest {
        var request = ListMembersRequest()
        request.requestHeader = APIRequestHeader.make()
        request.groupID = group
        request.fetchOptions = [4, 5]
        request.filter = 1
        if let pageToken, !pageToken.isEmpty {
            request.pageToken = pageToken
        }
        return request
    }
}
