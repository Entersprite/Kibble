import Foundation
import SwiftProtobuf

public enum WebhookRequests {
    public static func groupReference(_ group: GroupId) throws -> WebGroupReference {
        var result = WebGroupReference()
        switch group.id {
        case let .spaceID(value):
            result.id = "space/" + value.spaceID; result.rawID = value.spaceID; result.kind = 2
        case let .dmID(value):
            result.id = "dm/" + value.dmID; result.rawID = value.dmID; result.kind = 5
        case nil: throw ConversationActionRequestError.missingGroup
        }
        return result
    }

    public static func list(_ group: GroupId) throws -> BatchExecuteCall {
        var request = GetIncomingWebhooksRequest(); request.group = try groupReference(group)
        return try call("yVxlUd", request)
    }

    public static func create(_ group: GroupId, name: String, avatarURL: String) throws -> BatchExecuteCall {
        var request = CreateIncomingWebhookRequest()
        request.group = try groupReference(group); request.name = name
        request.avatarURL = avatarURL; request.avatarURLV2 = avatarURL
        return try call("yljFfb", request)
    }

    public static func update(
        _ id: WebhookReference,
        name: String,
        avatarURL: String
    ) throws -> BatchExecuteCall {
        var request = UpdateIncomingWebhookRequest(); request.id = id; request.name = name
        request.avatarURL = avatarURL; request.avatarURLV2 = avatarURL
        return try call("W7SEjd", request)
    }

    public static func delete(_ id: WebhookReference) throws -> BatchExecuteCall {
        var request = DeleteIncomingWebhookRequest(); request.id = id
        return try call("ITXKid", request)
    }

    private static func call(
        _ rpc: String,
        _ request: some SwiftProtobuf.Message
    ) throws -> BatchExecuteCall {
        try BatchExecuteCall(
            rpc: rpc,
            payload: PBLiteEncoder.encode(request).jsonString(),
            sourcePath: "/app"
        )
    }
}
