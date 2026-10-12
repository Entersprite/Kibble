import Foundation

public enum DirectConversationRequests {
    /// A single invitee, with no message or history-setting change.
    public static func create(userID: String) -> CreateDmRequest {
        var user = UserId()
        user.id = userID
        var invitee = InviteeInfo()
        invitee.userID = user
        var request = CreateDmRequest()
        request.requestHeader = APIRequestHeader.make()
        request.members = [user]
        request.invitees = [invitee]
        return request
    }
}

public extension APIMethod where Request == CreateDmRequest, Response == CreateDmResponse {
    static var createDm: Self {
        Self("create_dm")
    }
}
