import Foundation

/// `SBNmJb`'s inner payload, the message search (`findings.md` §65.2, §65.5,
/// §65.6), as far as the captures explain it. **No filter is here yet**:
/// their encodings are decoded (§65.5) but the group reference inside Said in
/// is not, and plan 2 adds them after the probe has run. Positions nobody has
/// explained are parameters, so the probe can try them.
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

    public init(
        text: String, queryID: String, pageToken: String? = nil, newestFirst: Bool = false,
        clientMillis: Int64? = nil, slot9: Int? = nil, slot11: String? = nil, slot12: Int = 1
    ) {
        self.text = text
        self.queryID = queryID
        self.pageToken = pageToken
        self.newestFirst = newestFirst
        self.clientMillis = clientMillis
        self.slot9 = slot9
        self.slot11 = slot11
        self.slot12 = slot12
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
        let scope: [Any] = [[[[[[1]]]]], [[[1]]]]
        let filter: [Any] = [
            [Any](),
            null,
            null,
            null,
            value(request.pageToken == nil ? request.queryID : nil),
            null,
            0,
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

    /// A query id the length of the captured ones (36). Their alphabet is not
    /// known; whether the server checks it is what the probe finds out.
    public static func newQueryID() -> String {
        UUID().uuidString.lowercased()
    }
}
