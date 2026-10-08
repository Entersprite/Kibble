import ChatKit
import GChatBridgeCore

/// `resolveAndEmitSelf()`, split out of `LocalBridgeBackend.swift` once it
/// pushed that file past swiftlint's `file_length` - the same convention
/// `LocalBridgeBackend+Capture.swift` and `LocalBridgeBackend+Errors.swift`
/// already established for extending this actor from a second file rather
/// than growing the first indefinitely.
extension LocalBridgeBackend {
    /// Who is running this session, via `get_self_user_status` -
    /// `findings.md` §3.6/§20.1's one call verified end to end against live
    /// traffic. The response carries only an id, never a name:
    /// `resolveAndEmitMembers` fills the name in separately, the ordinary
    /// way, once the local user turns up as a member of one of their own
    /// conversations - inventing a name here would be a guess dressed up as
    /// data.
    ///
    /// **Never throws**, the same posture `resolveAndEmitMembers` takes
    /// toward its own call: a failure here is a degraded title, not a broken
    /// session, so it becomes a `.backendError` event instead of taking
    /// `connect()` down with it.
    func resolveAndEmitSelf() async {
        guard let apiClient else { return }
        let response: GetSelfUserStatusResponse
        do {
            response = try await apiClient.call(.getSelfUserStatus, GetSelfUserStatusRequest())
        } catch {
            emit(.backendError(
                Self.chatError(fromAPI: error, call: "the /api/ get_self_user_status call")
            ))
            return
        }
        let id = response.userStatus.userID.id
        guard !id.isEmpty else {
            emit(.backendError(.unknown("get_self_user_status returned no user id")))
            return
        }
        emit(.selfIdentified(ChatKit.Member(id: ChatKit.Member.ID(id), kind: .human)))
        // The account's own name. The world lists it only as a member of a
        // DM or group chat, so an account with neither showed its raw id in
        // the sidebar footer.
        calendarPoll.me = ChatKit.Member.ID(id)
        // Awaited, so the calendar poll, which waits for this task, never
        // writes to a row that does not exist yet.
        await lookUpUnknownMembers([ChatKit.Member.ID(id)])
    }
}
