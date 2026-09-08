import ChatKit
import Foundation
import GChatBridgeCore

/// Publishing this client's read position - `.markRead`.
///
/// Its own file for the same reason `+History.swift`, `+Directory.swift` and
/// `+Send.swift` are: swiftlint's `file_length`, and this is a coherent
/// concern rather than an arbitrary cut.
public extension LocalBridgeBackend {
    /// **Confirmed behaviour, not an experiment** - `findings.md` §36,
    /// measured 2026-09-07. **The server's read comparison is
    /// strictly-greater-than.** A `last_read_time` exactly equal to a
    /// message's own `create_time` does not cover that message: session 21's
    /// first live run left the acknowledged read position equal, to the
    /// millisecond, to the newest message the client held, and the sender
    /// still saw their own message as unread on their phone.
    ///
    /// Publishing one microsecond past it fixed that, and the confirming
    /// capture is in §36.1 - two accepted calls, HTTP 200, 38 bytes out, 368
    /// back, `protoFields=1:2:345|2:2:18`, and the owner confirming the other
    /// person's phone then showed the message as read.
    ///
    /// **Neither reference documents this.** maugclib's
    /// `update_read_timestamp` (`maugclib/client.py:323-333`) has no callers,
    /// so it never exercised the boundary. purple
    /// (`googlechat_conversation.c:2748`) sidesteps it by sending corrected
    /// current time (`g_get_real_time() - (ha->server_time_offset *
    /// 1000000)`), which is strictly greater than anything it could mark, and
    /// never says why.
    ///
    /// **Why one microsecond and not corrected-now - do not undo this.**
    /// purple can send a corrected clock because it *maintains a measured
    /// server time offset*. This client has none, so its "now" would be an
    /// uncorrected local clock - precisely the defect session 21's
    /// whole-branch review removed, where every send published a receipt
    /// stamped from the local wall clock and a clock running ahead also
    /// poisoned the watermark. A wall-clock now additionally claims to have
    /// read messages arriving between computing the value and the server
    /// processing it; one microsecond past a *known* message claims
    /// essentially nothing extra, which is spec §5.2's semantics.
    ///
    /// `MarkReadTests.markReadPostsTheReferencesShape` pins the serialized
    /// bytes and is now a regression test for this protocol fact.
    ///
    /// **This is one half of a two-part workaround, and the other half is not
    /// in this package - see `findings.md` §36.7.** The same read-receipt
    /// defect turned out to depend on a second variable, the *age* of the
    /// message at the moment its position is published: a mark issued within
    /// roughly a quarter of a second of a message arriving does not register
    /// for the sender, and the offset above does not help. The fix for that
    /// is a two-second wait before the position is published, and it lives in
    /// `ChatSessionModel.markReadDebounce` because recomputing the position
    /// after the wait needs the loaded message list, which nothing below this
    /// seam has. **A future out-of-repo `RemoteBackend` or bridge server
    /// therefore inherits this constant and does not inherit the wait**, and
    /// would reproduce the 0.25s defect while publishing a value that looks
    /// correct everywhere it can see. §36.7 is what to read before writing
    /// one.
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
