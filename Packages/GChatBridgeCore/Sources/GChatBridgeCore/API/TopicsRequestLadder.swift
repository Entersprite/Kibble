import Foundation
import SwiftProtobuf

/// What one rung of the topics ladder came back with.
///
/// A close twin of `WorldRungResult` - see that type's own doc comment for why
/// this reports field **numbers**, counts and a status and never a value: a
/// `list_topics` response carries real message content, more so than a world
/// response does.
public struct TopicsRungResult: Sendable, Hashable {
    public let label: String
    public let status: Int?
    public let byteCount: Int
    public let encoding: APIResponseEncoding?
    public let fields: [ProtoField]
    public let truncated: Bool
    public let failure: String?

    /// Field numbers found **inside** each `topics` (field 1) entry, one array
    /// per topic, in response order. The same gap `WorldRungResult.worldItemFields`
    /// closed for `WorldItemLite` - `list_topics` has never been sent by this
    /// implementation, so which fields inside one `Topic` are actually
    /// populated has never been observed either. Empty when the rung carried
    /// no `topics` (the control is expected to be one of these).
    public let topicFields: [[ProtoField]]

    public init(
        label: String,
        status: Int?,
        byteCount: Int,
        encoding: APIResponseEncoding?,
        fields: [ProtoField],
        truncated: Bool,
        failure: String?,
        topicFields: [[ProtoField]] = []
    ) {
        self.label = label
        self.status = status
        self.byteCount = byteCount
        self.encoding = encoding
        self.fields = fields
        self.truncated = truncated
        self.failure = failure
        self.topicFields = topicFields
    }
}

/// Four candidate `ListTopicsRequest` shapes, and a runner that tries them
/// all - `WorldRequestLadder`'s sibling for history rather than the
/// conversation list.
///
/// ## Why a ladder here too
///
/// `list_topics` (and `list_messages`) have **never been sent by anything in
/// this project, in any language** - not this Swift implementation, not
/// `gchat-probe`, not a captured browser session. The only worked example is
/// the reference (`mautrix_googlechat/portal.py:406-446`), and `findings.md`
/// §20.1 already recorded what happened the last time a shape was taken from
/// a reference and trusted without a live run: `paginated_world` needed a
/// four-rung ladder to find a shape *neither* reference implementation had
/// right. Expect the same here rather than assume the reference's shape is
/// the whole story.
///
/// ## What is different from `WorldRequestLadder`
///
/// Every rung needs a `GroupId` - history is scoped to one conversation,
/// where the world call is not - so `rungs(for:)` is a function of a group
/// rather than a static list, and so is `minimumViable(for:)`.
///
/// 1. **Control** - `request_header` + `group_id` only. Expected to
///    under-perform, the same role rung 1 plays in `WorldRequestLadder`:
///    without it, a rung 2 success cannot be told apart from this account,
///    credential or client simply differing from whatever run comes next,
///    rather than the request shape mattering at all.
/// 2. **+ `page_size_for_topics: 50`** - the reference's own shape
///    (`portal.py:408-416`). The reference does not hardcode 50: it reads
///    `bridge.backfill.initial_thread_limit` /
///    `initial_nonthread_limit` from its own config, so 50 is this ladder's
///    stand-in for "some positive page size", not a literal taken from the
///    reference.
/// 3. **+ `page_size_for_replies: 50`** - what brings a thread's replies with
///    its first message. §20.4 once read every conversation as flat;
///    `findings.md` §63.5 has since sent this rung live against threads and
///    measured what it adds over rung 2, and history sends it
///    (`history(for:)`).
/// 4. **+ `fetch_options: [USER, TOTAL_MESSAGE_COUNTS, READ_RECEIPTS]`** - the
///    vendored proto's own enum for this request, used by neither reference.
///    Added to see whether it changes anything, the same role
///    `EXCLUDE_GROUP_LITE` played in `WorldRequestLadder`'s rung 4 - and
///    §20.1's finding there (it *cost* data rather than saving a round trip)
///    is exactly why this is not assumed to help.
public enum TopicsRequestLadder {
    public struct Rung: Sendable {
        public let label: String
        /// Where this shape came from, so a result can be traced to a claim.
        public let source: String
        public let request: ListTopicsRequest
    }

    public static func rungs(for group: GroupId) -> [Rung] {
        [
            Rung(
                label: "1 control: header + group_id",
                source: "the shape neither reference implementation needs to add anything to - "
                    + "expected to under-perform, the same role WorldRequestLadder's rung 1 plays",
                request: control(group)
            ),
            Rung(
                label: "2 + page_size_for_topics: 50",
                source: "mautrix_googlechat/portal.py:408-416 - the reference's own shape "
                    + "(the page size itself is configured there, not a literal; 50 is this "
                    + "ladder's stand-in)",
                request: withTopicsPageSize(group)
            ),
            Rung(
                label: "3 + page_size_for_replies: 50",
                source: "mautrix_googlechat/portal.py:428-436 - the threaded-reply follow-up's "
                    + "own page size, layered onto the topics request rather than sent as a "
                    + "separate list_messages call",
                request: withRepliesPageSize(group)
            ),
            Rung(
                label: "4 + fetch_options: [USER, TOTAL_MESSAGE_COUNTS, READ_RECEIPTS]",
                source: "the vendored proto's own ListTopicsRequest.FetchOptions - used by "
                    + "neither reference",
                request: withFetchOptions(group)
            )
        ]
    }

    /// The reference's own request (`rungs(for:)[1]`), which the probes keep
    /// as their baseline.
    ///
    /// Rung 2 was history's request from session 12 until the threads work,
    /// and the probes still compare against it; history now sends
    /// `history(for:)` (rung 3). Rungs 2 and 3 have both been sent live
    /// (`findings.md` §63.5).
    public static func minimumViable(for group: GroupId) -> Rung {
        rungs(for: group)[1]
    }

    /// What history sends since the threads work (threads spec §2.2): rung 3,
    /// the reference's request plus `page_size_for_replies: 50`, so a thread's
    /// replies arrive with its first message (`findings.md` §63.5, about 2.4
    /// times rung 2's bytes on the probed space). Rung 4 instead, if the
    /// owner's §64.9 run shows its `TOTAL_MESSAGE_COUNTS` brings
    /// `TopicReadState` field 10.
    public static func history(for group: GroupId) -> Rung {
        rungs(for: group)[2]
    }

    private static func control(_ group: GroupId) -> ListTopicsRequest {
        var request = ListTopicsRequest()
        request.requestHeader = APIRequestHeader.make()
        request.groupID = group
        return request
    }

    private static func withTopicsPageSize(_ group: GroupId) -> ListTopicsRequest {
        var request = control(group)
        request.pageSizeForTopics = 50
        return request
    }

    private static func withRepliesPageSize(_ group: GroupId) -> ListTopicsRequest {
        var request = withTopicsPageSize(group)
        request.pageSizeForReplies = 50
        return request
    }

    private static func withFetchOptions(_ group: GroupId) -> ListTopicsRequest {
        var request = withRepliesPageSize(group)
        request.fetchOptions = [.user, .totalMessageCounts, .readReceipts]
        return request
    }

    /// Sends every rung and records what came back.
    ///
    /// A failing rung is recorded and the ladder continues: the point is the
    /// comparison, and a failure on one rung is itself a result.
    public static func run(
        _ rungs: [Rung],
        with client: ProtoAPIClient
    ) async -> [TopicsRungResult] {
        var results: [TopicsRungResult] = []
        for rung in rungs {
            await results.append(runOne(rung, with: client))
        }
        return results
    }

    private static func runOne(_ rung: Rung, with client: ProtoAPIClient) async -> TopicsRungResult {
        do {
            let body: Data = try rung.request.serializedBytes()
            let raw = try await client.callRaw(APIMethod.listTopics.name, body: body)
            // Untyped on purpose: a typed decode drops the fields the vendored
            // proto cannot name, which is exactly what this is looking for.
            let candidates = APIResponseBody.candidates(raw.body)
            let best = candidates.first { !ProtoFieldScan.fields(in: $0.bytes).truncated }
                ?? candidates.first
            let scan: (fields: [ProtoField], truncated: Bool) = if let best {
                ProtoFieldScan.fields(in: best.bytes)
            } else {
                (fields: [], truncated: false)
            }
            // Every `topics` (field 1) entry, scanned again one level down -
            // the topics analogue of what WorldRequestLadder does for
            // `world_items` (field 4).
            let topicFields: [[ProtoField]] = if let best {
                ProtoFieldScan.payloads(ofField: 1, in: best.bytes)
                    .map { ProtoFieldScan.fields(in: $0).fields }
            } else {
                []
            }
            return TopicsRungResult(
                label: rung.label,
                status: raw.status,
                byteCount: raw.body.count,
                encoding: best?.encoding,
                fields: scan.fields,
                truncated: scan.truncated,
                failure: nil,
                topicFields: topicFields
            )
        } catch {
            // Same reasoning as `WorldRequestLadder.runOne`'s catch: `callRaw`
            // only ever throws `APIFailure`, but the fallback is for whatever
            // it gets replaced with later not staying that way, and
            // `String(describing: error)` on anything else must not carry
            // request content into a report a human pastes into `findings.md`.
            let apiFailure = error as? APIFailure
            return TopicsRungResult(
                label: rung.label,
                status: apiFailure.flatMap {
                    if case let .httpStatus(status) = $0 {
                        return status
                    }
                    return nil
                },
                byteCount: 0,
                encoding: nil,
                fields: [],
                truncated: false,
                failure: apiFailure?.safeDescription ?? String(describing: type(of: error))
            )
        }
    }

    /// A human-readable summary. **Counts, statuses and field numbers only.**
    public static func report(_ results: [TopicsRungResult]) -> String {
        results.map(line(for:)).joined(separator: "\n")
    }

    private static func line(for result: TopicsRungResult) -> String {
        var parts = ["  \(result.label)"]
        if let failure = result.failure {
            parts.append("    FAILED: \(failure)")
            return parts.joined(separator: "\n")
        }
        let status = result.status.map(String.init) ?? "-"
        let encoding = result.encoding?.rawValue ?? "-"
        parts.append("    HTTP \(status), \(result.byteCount) wire bytes, \(encoding)")
        let fields = result.fields
            .map { "\($0.number):w\($0.wireType)=\($0.byteCount)B" }
            .joined(separator: " ")
        parts.append("    fields: \(fields.isEmpty ? "(none)" : fields)")
        if result.truncated {
            parts.append("    scan stopped early - an unreadable field, not necessarily bad data")
        }
        return parts.joined(separator: "\n")
    }
}
