import Foundation

/// Publishing this client's read position - `mark_group_readstate`.
///
/// ## Why there is no ladder here
///
/// The same reason `SendRequests` has none. `WorldRequestLadder` and
/// `TopicsRequestLadder` send four candidate shapes and let the comparison be
/// the finding, because a read costs nothing but latency. **This is a write.**
/// Four rungs would set read state four times on somebody's real account, and
/// read state is what other people's expectations of "have you seen this" are
/// built on. So this is one shape, copied from the one worked example, and
/// marked `[Verify]` until a single deliberate call confirms it.
///
/// ## Where the shape comes from
///
/// `reference/googlechat-master/maugclib/client.py:323-333`
/// (`update_read_timestamp`, the caller that actually builds the request -
/// `proto_mark_group_read_state` at `:730-736` is a bare passthrough that
/// constructs nothing): `request_header`, `id` as the `GroupId`, and
/// `last_read_time` in **microseconds** since the epoch - the same unit every
/// other timestamp on this protocol uses (`findings.md` §2.3).
public enum ReadStateRequests {
    public static func markGroupRead(
        group: GroupId,
        lastReadTime: Int64
    ) -> MarkGroupReadstateRequest {
        var request = MarkGroupReadstateRequest()
        request.requestHeader = APIRequestHeader.make()
        request.id = group
        request.lastReadTime = lastReadTime
        return request
    }
}
