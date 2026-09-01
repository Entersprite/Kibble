import Foundation
import SwiftProtobuf

/// What one rung of the ladder came back with.
///
/// Field **numbers**, counts and a status. No bytes, because a world response
/// carries real conversation names and this is written to a file a human reads.
public struct WorldRungResult: Sendable, Hashable {
    public let label: String
    public let status: Int?
    public let byteCount: Int
    public let encoding: APIResponseEncoding?
    public let fields: [ProtoField]
    public let truncated: Bool
    public let failure: String?

    public init(
        label: String,
        status: Int?,
        byteCount: Int,
        encoding: APIResponseEncoding?,
        fields: [ProtoField],
        truncated: Bool,
        failure: String?
    ) {
        self.label = label
        self.status = status
        self.byteCount = byteCount
        self.encoding = encoding
        self.fields = fields
        self.truncated = truncated
        self.failure = failure
    }
}

/// Four candidate `PaginatedWorldRequest` shapes, and a runner that tries them
/// all.
///
/// ## Why a ladder and not a request
///
/// `findings.md` §3.6 sent a minimal `PaginatedWorldRequest`
/// (`request_header` + `fetch_from_user_spaces`) and got back a response
/// carrying only field 11 (value 21) - no conversation list, and field 11 is
/// unnamed in the hand-written proto. §3.6 flagged the minimum viable request
/// shape as `[Verify]`. The two reference implementations disagree about what
/// closes that gap: `purple-googlechat` adds `fetch_snippets_for_unnamed_rooms`
/// plus a `world_section_requests` entry with `page_size: 999`
/// (`googlechat_conversation.c:1194-1211`), while `maugclib` adds a
/// `fetch_options: [EXCLUDE_GROUP_LITE]` instead and only appends a section
/// request when a sync limit is configured (`user.py:613-619`). Neither
/// reference is evidence on its own - both are code nobody has run against
/// live 2026 traffic and confirmed.
///
/// So rather than pick one and call it verified, all four are sent and the
/// difference is the finding:
///
/// 1. **Control** - exactly §3.6's shape. Expected to fail (field 11 only).
///    Included on purpose: without it, a success on rung 2 cannot be told
///    apart from this account, credential or client simply differing from the
///    run that produced §3.6, rather than the request shape mattering at all.
/// 2. **+ `world_section_requests`** - the one addition both references agree
///    on: a single section request with `page_size: 999`.
/// 3. **+ `fetch_snippets_for_unnamed_rooms`** - purple's full shape.
/// 4. **+ `fetch_options: [EXCLUDE_GROUP_LITE]`** - maugclib's shape, layered
///    on top of 3 rather than replacing it, so a success here does not by
///    itself say which of the two additions was load-bearing; that is a
///    question for a follow-up run, not this ladder.
public enum WorldRequestLadder {
    public struct Rung: Sendable {
        public let label: String
        /// Where this shape came from, so a result can be traced to a claim.
        public let source: String
        public let request: PaginatedWorldRequest
    }

    public static var rungs: [Rung] {
        [
            Rung(
                label: "1 control: header + fetch_from_user_spaces",
                source: "findings.md §3.6 - known to answer with field 11 only",
                request: control()
            ),
            Rung(
                label: "2 + world_section_requests[page_size: 999]",
                source: "the one difference both references share",
                request: withSection()
            ),
            Rung(
                label: "3 + fetch_snippets_for_unnamed_rooms",
                source: "purple-googlechat googlechat_conversation.c:1205-1210",
                request: purpleShape()
            ),
            Rung(
                label: "4 + fetch_options[EXCLUDE_GROUP_LITE]",
                source: "maugclib mautrix_googlechat/user.py:613-617",
                request: maugclibShape()
            )
        ]
    }

    private static func control() -> PaginatedWorldRequest {
        var request = PaginatedWorldRequest()
        request.requestHeader = APIRequestHeader.make()
        request.fetchFromUserSpaces = true
        return request
    }

    private static func section() -> WorldSectionRequest {
        var section = WorldSectionRequest()
        // purple sends 999; maugclib sends one only when a limit is configured.
        section.pageSize = 999
        return section
    }

    private static func withSection() -> PaginatedWorldRequest {
        var request = control()
        request.worldSectionRequests = [section()]
        return request
    }

    private static func purpleShape() -> PaginatedWorldRequest {
        var request = withSection()
        request.fetchSnippetsForUnnamedRooms = true
        return request
    }

    private static func maugclibShape() -> PaginatedWorldRequest {
        var request = purpleShape()
        request.fetchOptions = [.excludeGroupLite]
        return request
    }

    /// Sends every rung and records what came back.
    ///
    /// A failing rung is recorded and the ladder continues: the point is the
    /// comparison, and a 403 on one rung is itself a result.
    public static func run(
        _ rungs: [Rung],
        with client: ProtoAPIClient
    ) async -> [WorldRungResult] {
        var results: [WorldRungResult] = []
        for rung in rungs {
            await results.append(runOne(rung, with: client))
        }
        return results
    }

    private static func runOne(_ rung: Rung, with client: ProtoAPIClient) async -> WorldRungResult {
        do {
            let body: Data = try rung.request.serializedBytes()
            let raw = try await client.callRaw("paginated_world", body: body)
            // Untyped on purpose: a typed decode drops the fields the vendored
            // proto cannot name, which is exactly what this is looking for.
            let candidates = APIResponseBody.candidates(raw.body)
            let best = candidates.first { !ProtoFieldScan.fields(in: $0.bytes).truncated }
                ?? candidates.first
            // Spelled out rather than `?? ([], false)`: the tuple is labelled,
            // and coercing an unlabelled literal into it is the kind of thing
            // that compiles here and not on the next toolchain.
            let scan: (fields: [ProtoField], truncated: Bool) = if let best {
                ProtoFieldScan.fields(in: best.bytes)
            } else {
                (fields: [], truncated: false)
            }
            return WorldRungResult(
                label: rung.label,
                status: raw.status,
                byteCount: raw.body.count,
                encoding: best?.encoding,
                fields: scan.fields,
                truncated: scan.truncated,
                failure: nil
            )
        } catch {
            return WorldRungResult(
                label: rung.label,
                status: (error as? APIFailure).flatMap {
                    if case let .httpStatus(status) = $0 {
                        return status
                    }
                    return nil
                },
                byteCount: 0,
                encoding: nil,
                fields: [],
                truncated: false,
                failure: String(describing: error)
            )
        }
    }

    /// A human-readable summary. **Counts, statuses and field numbers only.**
    public static func report(_ results: [WorldRungResult]) -> String {
        results.map(line(for:)).joined(separator: "\n")
    }

    private static func line(for result: WorldRungResult) -> String {
        var parts = ["  \(result.label)"]
        if let failure = result.failure {
            parts.append("    FAILED: \(failure)")
            return parts.joined(separator: "\n")
        }
        let status = result.status.map(String.init) ?? "-"
        let encoding = result.encoding?.rawValue ?? "-"
        parts.append("    HTTP \(status), \(result.byteCount) bytes, \(encoding)")
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
