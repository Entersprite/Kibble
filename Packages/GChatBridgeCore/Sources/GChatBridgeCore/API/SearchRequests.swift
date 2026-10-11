import Foundation

/// `SBNmJb`'s inner payload, the message search (`findings.md` §65.2, §65.5,
/// §65.6), as far as the captures explain it. The filters are the ones
/// §65.5's second capture isolated one chip at a time: `fromUserID`,
/// `olderThanMicros`, `hasFile`, `hasLink`, `mentionsUserID` and
/// `conversationSpaceID` (Said in, spaces only - no DM Said in was ever
/// captured, and `LocalBridgeBackend.searchMessages` refuses one rather than
/// guessing its shape). Positions nobody has explained are parameters, so the
/// probe can try them.
public struct MessageSearchPayload: Sendable, Hashable {
    public var text: String
    /// Position 5, new per query, the same across its pages.
    public var queryID: String
    /// Position 1, from the previous page's answer.
    public var pageToken: String?
    /// Position 8: `[2]` newest first, `[3]` by relevance.
    public var newestFirst: Bool
    /// Position 7, the client's clock in milliseconds, on later pages.
    public var clientMillis: Int64?
    /// Position 9: `[99]`, `[113]`, `[191]` in captures, changing between page
    /// loads. Unexplained.
    public var slot9: Int?
    /// Position 11: 32 chars, the same on every call of a session. Unexplained.
    public var slot11: String?
    /// Position 12: 1, 2, 3 across a session. Unexplained.
    public var slot12: Int

    /// Filter position 6, index 1: `6[1] = [[userId]]` (§65.5, the From chip).
    public var fromUserID: String?
    /// Filter position 6, index 2: `6[2] = [null, "<µs>"]`, an upper bound in
    /// microseconds, sent as a decimal string (§65.5, "Date: Older than").
    public var olderThanMicros: Int64?
    /// Filter position 6, index 3: `6[3] = [[2]]` (§65.5, "Has file: Any
    /// file"). The chip's submenu of file types is `[Verify]`; this is the
    /// one value the capture saw.
    public var hasFile: Bool
    /// Filter position 6, index 6: `6[6] = 1`, base `0` (§65.5, "Has link").
    public var hasLink: Bool
    /// Filter position 6, index 5: `6[5] = [[[[myUserId]]]]` (§65.5, "Mentions
    /// me").
    public var mentionsUserID: String?
    /// The raw space id for "Said in" (§65.5, §65.8): filter position 6
    /// changes at **two** indices together, 0 and 7. Only a space's reference
    /// was ever captured - `nil` leaves both indices at their default
    /// ("conversations I'm in").
    public var conversationSpaceID: String?

    public init(
        text: String, queryID: String, pageToken: String? = nil, newestFirst: Bool = false,
        clientMillis: Int64? = nil, slot9: Int? = nil, slot11: String? = nil, slot12: Int = 1,
        fromUserID: String? = nil, olderThanMicros: Int64? = nil, hasFile: Bool = false,
        hasLink: Bool = false, mentionsUserID: String? = nil, conversationSpaceID: String? = nil
    ) {
        self.text = text
        self.queryID = queryID
        self.pageToken = pageToken
        self.newestFirst = newestFirst
        self.clientMillis = clientMillis
        self.slot9 = slot9
        self.slot11 = slot11
        self.slot12 = slot12
        self.fromUserID = fromUserID
        self.olderThanMicros = olderThanMicros
        self.hasFile = hasFile
        self.hasLink = hasLink
        self.mentionsUserID = mentionsUserID
        self.conversationSpaceID = conversationSpaceID
    }
}

public enum SearchRequests {
    public static let rpc = "SBNmJb"
    public static let sourcePath = "/app/search"

    /// The JSON string `BatchExecute.request(payload:)` nests.
    public static func payload(_ request: MessageSearchPayload) -> String {
        let null = NSNull()
        /// JSON `null` for `nil`: `??` cannot mix a value's type with `NSNull`.
        func value(_ optional: Any?) -> Any {
            optional ?? null
        }
        // "Conversations I'm in", the default scope (§65.5, filter position 7).
        let defaultScope: [Any] = [[[[[[1]]]]], [[[1]]]]

        // Said in (§65.5, §65.8): a space's own group reference - the exact
        // shape `SearchHitMapping.groupReference(_:)` reads back out of a hit
        // - and the scope narrowed to that one space. Both filter indices
        // (0 and 7) change together; neither is set for the default scope.
        let saidIn: Any
        let scope: Any
        if let spaceID = request.conversationSpaceID {
            let groupReference: [Any] = ["space/\(spaceID)", spaceID, 2]
            saidIn = [null, groupReference] as [Any]
            let onlyThisSpace = Self.nest(spaceID, depth: 2) // [[spaceId]]
            let pair: [Any] = [onlyThisSpace, 1] // [[[spaceId]],1]
            scope = [null, null, null, [pair]] as [Any] // [null,null,null,[[[[spaceId]],1]]]
        } else {
            saidIn = [Any]()
            scope = defaultScope
        }

        let filter: [Any] = [
            saidIn,
            value(request.fromUserID.map { Self.nest($0, depth: 2) }), // [[userId]]
            value(request.olderThanMicros.map { [null, String($0)] as [Any] }),
            value(request.hasFile ? ([[2]] as [Any]) : nil),
            value(request.pageToken == nil ? request.queryID : nil),
            value(request.mentionsUserID.map { Self.nest($0, depth: 4) }), // [[[[myUserId]]]]
            request.hasLink ? 1 : 0,
            scope
        ]
        let payload: [Any] = [
            null, value(request.pageToken), null, request.text, null, request.queryID, filter,
            value(request.clientMillis.map { NSNumber(value: $0) }),
            [request.newestFirst ? 2 : 3],
            value(request.slot9.map { [$0] }),
            0,
            value(request.slot11),
            request.slot12
        ]
        let data = (
            try? JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes])
        ) ??
            Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Wraps `id` in `depth` nested one-element arrays: `nest("x", depth: 2)
    /// == [["x"]]`. Every multi-level id wrapper the filter structure uses
    /// (§65.5's `[[userId]]`, `[[[[myUserId]]]]`, and the two-level piece
    /// inside Said in's scope override) is this, spelled out once rather than
    /// hand-counted brackets at each call site.
    private static func nest(_ id: String, depth: Int) -> Any {
        var value: Any = id
        for _ in 0 ..< depth {
            value = [value]
        }
        return value
    }

    /// A query id the length of the captured ones (36). Their alphabet is not
    /// known; whether the server checks it is what the probe finds out.
    public static func newQueryID() -> String {
        UUID().uuidString.lowercased()
    }
}
