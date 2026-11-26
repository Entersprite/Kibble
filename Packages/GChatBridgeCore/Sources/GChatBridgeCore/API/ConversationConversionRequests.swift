import Foundation

public enum ConversationConversionRequests {
    public static func convert(_ group: GroupId, name: String, emoji: String?) throws -> BatchExecuteCall {
        var request = ConvertChatToSpaceRequest()
        request.group = try WebhookRequests.groupReference(group)
        request.name = name; request.updateMasks = [1, 7]
        var attribute = WebGroupAttribute(); attribute.type = 6; attribute.value = "SPACE"
        request.attributes = [attribute]
        if let emoji {
            request.avatar.emoji.unicode = emoji
            request.updateMasks.append(3)
        }
        return try BatchExecuteCall(
            rpc: "JpvLpe", payload: PBLiteEncoder.encode(request).jsonString(), sourcePath: "/app"
        )
    }
}
