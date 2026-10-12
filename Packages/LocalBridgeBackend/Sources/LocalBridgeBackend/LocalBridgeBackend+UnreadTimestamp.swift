import ChatKit
import GChatBridgeCore

extension LocalBridgeBackend {
    /// The browser's NyBsFc adapter delegates to this native API call.
    func setConversationUnreadTimestamp(group: GroupId, micros: Int64) async throws {
        guard let apiClient else { throw ChatError.notAuthenticated }
        let method = "set_mark_as_unread_timestamp"
        do {
            let response = try await apiClient.call(
                .setMarkAsUnreadTimestamp,
                ConversationActionRequests.unread(group: group, micros: micros)
            )
            try Task.checkCancellation()
            guard ThreadCallRequests.answer(response, carries: 1) else {
                onConversationAction?(ConversationActionObservation(
                    rpc: method, status: 200, serviceCode: nil, outcome: "unconfirmed"
                ))
                throw ChatError.decoding("The service did not confirm the unread mark (field 1 absent).")
            }
            onConversationAction?(ConversationActionObservation(
                rpc: method, status: 200, serviceCode: nil, outcome: "accepted"
            ))
        } catch let error as APIFailure {
            if !Task.isCancelled {
                let status: Int? = if case let .httpStatus(value) = error {
                    value
                } else {
                    nil
                }
                onConversationAction?(ConversationActionObservation(
                    rpc: method, status: status, serviceCode: nil, outcome: "apiFailure"
                ))
            }
            throw Self.chatError(fromAPI: error, call: "setting the unread mark")
        }
    }
}
