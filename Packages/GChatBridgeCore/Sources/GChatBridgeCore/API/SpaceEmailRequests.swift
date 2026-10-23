import Foundation

public enum SpaceEmailRequests {
    public static func read(_ group: GroupId) -> ListSpaceEmailRequest {
        var request = ListSpaceEmailRequest()
        request.requestHeader = APIRequestHeader.make(); request.group = group
        return request
    }

    public static func delivery(
        _ enabled: Bool,
        for details: SpaceEmailDetails,
        in group: GroupId
    ) -> UpdateSpaceEmailRequest {
        var value = details; value.emailDeliverySetting = enabled ? 2 : 1
        var request = UpdateSpaceEmailRequest()
        request.requestHeader = APIRequestHeader.make(); request.group = group
        request.email = details.email; request.details = value
        request.updateMask.paths = ["emailable_space_details.email_delivery_setting"]
        return request
    }

    public static func delete(_ email: String, in group: GroupId) -> DeleteSpaceEmailRequest {
        var request = DeleteSpaceEmailRequest()
        request.requestHeader = APIRequestHeader.make(); request.group = group; request.email = email
        return request
    }
}

public extension APIMethod where Request == ListSpaceEmailRequest, Response == ListSpaceEmailResponse {
    static var listSpaceEmail: Self {
        Self("list_emailable_space_details")
    }
}

public extension APIMethod where Request == ListSpaceEmailRequest, Response == GenerateSpaceEmailResponse {
    static var generateSpaceEmail: Self {
        Self("generate_space_email")
    }
}

public extension APIMethod where Request == UpdateSpaceEmailRequest, Response == UpdateSpaceEmailResponse {
    static var updateSpaceEmail: Self {
        Self("update_emailable_space_details")
    }
}

public extension APIMethod where Request == DeleteSpaceEmailRequest, Response == DeleteSpaceEmailResponse {
    static var deleteSpaceEmail: Self {
        Self("delete_space_email", allowsEmptyResponse: true)
    }
}
