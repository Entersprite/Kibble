import ChatKit
import Foundation
import GChatBridgeCore

/// Publishing this client's read position - `.markRead`.
///
/// Its own file for the same reason `+History.swift`, `+Directory.swift` and
/// `+Send.swift` are: swiftlint's `file_length`, and this is a coherent
/// concern rather than an arbitrary cut.
public extension LocalBridgeBackend {
    /// Marks one conversation read up to `date`, and emits what the server
    /// says the resulting read state is.
    ///
    /// **The response is the read state, and the client does not compute one.**
    /// `MarkGroupReadstateResponse.read_state` carries both `last_read_time`
    /// and `unread_message_count`, so the badge is always the server's number.
    /// That is deliberate: this client keeps no local read watermark, so
    /// there is no second number that can be wrong.
    ///
    /// **An absent `read_state` throws.** Auth failure returns HTTP 200 on
    /// this protocol, so "did not throw" has never been proof of anything -
    /// and a mark-read that quietly did not happen leaves a badge that never
    /// clears with nothing reported, which is the worst failure shape this
    /// project produces (session 13 §2.2).
    ///
    /// **No retry of its own.** A failure records through
    /// `SyncEngine.submit(_:)` and the next ordinary trigger tries again,
    /// because the caller's watermark advances only on success.
    func markRead(_ conversationID: Conversation.ID, upTo date: Date) async throws {
        guard let apiClient else {
            throw ChatError.unknown(
                "markRead(_:upTo:) requires connect() to succeed first - "
                    + "there is no verified session or xsrf token yet"
            )
        }
        guard let group = ChannelEventMapping.groupID(for: conversationID) else {
            throw ChatError.unknown(
                "\(conversationID.rawValue) has neither the space/ nor the dm/ prefix "
                    + "this backend produces, so no mark_group_readstate request "
                    + "can be built for it"
            )
        }
        let response: MarkGroupReadstateResponse
        do {
            response = try await apiClient.call(
                .markGroupReadstate,
                ReadStateRequests.markGroupRead(
                    group: group, lastReadTime: Microseconds.from(date)
                )
            )
        } catch {
            throw Self.chatError(fromAPI: error, call: "the /api/ mark_group_readstate call")
        }
        guard response.hasReadState else {
            throw ChatError.unknown(
                "mark_group_readstate answered 200 with no read_state, so nothing "
                    + "confirms the mark - field 1 absent"
            )
        }
        emit(.readStateChanged(
            conversationID: conversationID,
            lastReadAt: Microseconds.date(response.readState.lastReadTime),
            unread: Int(response.readState.unreadMessageCount)
        ))
    }
}
