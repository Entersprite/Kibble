public enum BlockedRoomRequests {
    public static func list() -> BatchExecuteCall {
        BatchExecuteCall(rpc: "abmOGd", payload: "[]", sourcePath: "/app/home")
    }

    public static func unblock(_ group: GroupId) throws -> BatchExecuteCall {
        var request = UnblockRoomRequest()
        request.group = try WebhookRequests.groupReference(group)
        request.blocked = false
        request.reported = false
        return try BatchExecuteCall(
            rpc: "BFhA9d", payload: PBLiteEncoder.encode(request).jsonString(), sourcePath: "/app/home"
        )
    }
}
