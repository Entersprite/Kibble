import GChatBridgeCore

/// What reporting activity sends (active-presence spec §1). `[Verify]` until
/// the owner's run.
enum ActivityRequests {
    /// purple's shape: the header and `user_state`, nothing else.
    static func heartbeat(active: Bool) -> HeartbeatRequest {
        var request = HeartbeatRequest()
        request.requestHeader = APIRequestHeader.make()
        request.presenceUpdateRequest.userState = active ? .active : .inactive
        return request
    }
}
