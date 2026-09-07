import ChatKit
import Foundation
import GChatBridgeCore

/// Publishing this client's read position - `.markRead`.
///
/// Its own file for the same reason `+History.swift`, `+Directory.swift` and
/// `+Send.swift` are: swiftlint's `file_length`, and this is a coherent
/// concern rather than an arbitrary cut.
public extension LocalBridgeBackend {
    /// **An experiment with a stated hypothesis, not a settled fix** - session
    /// 21's diagnosis. A live run showed six `mark_group_readstate` calls all
    /// accepted at 518-750ms, with the server-acknowledged read position
    /// ending up exactly equal, to the millisecond, to the newest message the
    /// client held (`lastReadAt` `2026-09-07 13:22:32.128` against that
    /// message's own `createdAt`). Despite that, the sender's own phone still
    /// showed their message as unread.
    ///
    /// **Hypothesis: the server's read comparison is strictly-greater-than.**
    /// Publishing `last_read_time` exactly equal to a message's `create_time`
    /// leaves that message uncovered by the read position, so the sender
    /// correctly sees it unread. The one reference implementation that
    /// actually issues this call,
    /// `reference/purple-googlechat-master/googlechat_conversation.c:2748`,
    /// never hits this boundary at all - it sends corrected current time
    /// (`g_get_real_time() - (ha->server_time_offset * 1000000)`), which is
    /// strictly greater than every message it could ever mark.
    ///
    /// **Why one microsecond and not "send now".** Switching to corrected-now
    /// would change the boundary *and* the semantics in the same step, and
    /// `findings.md` §12.4 is this project's own recorded regret about
    /// exactly that: a probe that changed two variables at once, so neither
    /// could be credited. Adding one microsecond tests only the boundary, and
    /// it keeps spec §5.2's reasoning intact - a wall-clock now would claim to
    /// have read messages that arrive between computing the value and the
    /// server processing it, while one microsecond past a *known* message
    /// claims essentially nothing extra.
    ///
    /// **What would confirm this, and what would refute it.** Confirms: the
    /// next live run's acknowledged `lastReadTime` is one microsecond past the
    /// newest message's `createdAt` (not equal to it), and the sender sees the
    /// message as read. Refutes: the sender still sees it unread despite that
    /// offset, which would mean the boundary hypothesis is wrong and the
    /// residual-unread bug lives somewhere else entirely - not in the
    /// equality, and not in this file.
    static let readPositionOffsetMicroseconds: Int64 = 1

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
                    group: group,
                    lastReadTime: Microseconds.adding(
                        Self.readPositionOffsetMicroseconds, to: Microseconds.from(date)
                    )
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
