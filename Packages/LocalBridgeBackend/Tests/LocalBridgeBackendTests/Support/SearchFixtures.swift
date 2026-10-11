import Foundation
import GChatBridgeCore

/// Building a hit, a page's inner payload, and a `batchexecute` answer body
/// - the shapes `findings.md` §65.2, §65.6 and §65.8 describe - plus reading
/// a sent request's own inner payload back out. Shared across every
/// `SearchMessages*Tests.swift` file, the same reason `SearchTransport` is
/// not `private`.
enum SearchFixtures {
    /// The full shell `BatchExecuteContext` needs: `SNlM0e`, `FdrFJe` and
    /// `cfb2h`, none of which `LocalBridgeBackendTests.shell(app:)` carries -
    /// that helper predates search and is used by suites that never reach
    /// `batchexecute`.
    static func fullShell(app: String = "DynamiteWebUi") -> HTTPResponse {
        let html = """
        <script nonce="x">window.WIZ_global_data = ({"qwAQke":"\(app)",\
        "SMqcke":"\(String(repeating: "t", count: 42))",\
        "SNlM0e":"\(String(repeating: "a", count: 42))",\
        "FdrFJe":"fsid-1","cfb2h":"boq_x"});</script>
        """
        return HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data(html.utf8))
    }

    /// A hit in the shape §65.8 found: `[inner, 2]`, `inner` a pblite message
    /// with field N at index N-1. Only the fields `SearchHitMapping` actually
    /// reads are filled in.
    static func hit(
        messageID: String, topicID: String? = nil, spaceID: String, senderID: String,
        text: String, createdAtMicros: Int64
    ) -> [Any] {
        var fields = [Any](repeating: NSNull(), count: 18)
        let groupReference: [Any] = ["space/\(spaceID)", spaceID, 2]
        fields[2] = groupReference // field 3
        fields[4] = [senderID] // field 5
        fields[5] = text // field 6
        fields[11] = String(createdAtMicros) // field 12
        fields[17] = [messageID, NSNull(), [topicID ?? messageID, NSNull(), groupReference]] // field 18
        return [fields, 2]
    }

    /// The `SBNmJb` answer's own inner array (§65.2): only indices 0 (the
    /// next token) and 9 (the hits) are ones `SearchHitMapping.page(from:)`
    /// reads; the rest are left `null`.
    static func pageInner(nextToken: String?, hits: [[Any]]) -> [Any] {
        var inner = [Any](repeating: NSNull(), count: 10)
        inner[0] = nextToken ?? NSNull()
        inner[9] = hits
        return inner
    }

    /// One `wrb.fr` row, framed as a `batchexecute` answer body (§65.6):
    /// `)]}'` then a balanced JSON array - the length line `BatchExecute
    /// .answers(in:)` itself says it never trusts. `rpc` defaults to
    /// `SBNmJb`'s own; a test naming a different one builds an answer
    /// `searchMessages` must report as carrying no `SBNmJb` row at all.
    static func answerBody(inner: [Any], errorCode: Int? = nil, rpc: String = SearchRequests.rpc) throws
        -> Data {
        let payloadData = try JSONSerialization.data(
            withJSONObject: inner, options: [.withoutEscapingSlashes]
        )
        let payloadString = String(decoding: payloadData, as: UTF8.self)
        return try rawAnswerBody(payload: payloadString, errorCode: errorCode, rpc: rpc)
    }

    /// The same framing, with the payload a literal string instead of a JSON
    /// encoding of an array - for a row whose payload is not valid JSON at
    /// all, which `answerBody(inner:)` cannot build since it always encodes
    /// one.
    static func answerBody(undecodablePayload payload: String) throws -> Data {
        try rawAnswerBody(payload: payload, errorCode: nil, rpc: SearchRequests.rpc)
    }

    private static func rawAnswerBody(payload: String, errorCode: Int?, rpc: String) throws -> Data {
        let row: [Any] = [
            "wrb.fr", rpc, payload, NSNull(), NSNull(),
            errorCode.map { [$0] } ?? NSNull()
        ]
        let frame: [Any] = [row]
        let frameData = try JSONSerialization.data(withJSONObject: frame, options: [.withoutEscapingSlashes])
        return Data(")]}'\n".utf8) + frameData
    }

    static func ok(_ data: Data) -> Result<HTTPResponse, any Error> {
        .success(HTTPResponse(status: 200, headers: HTTPHeaders([]), body: data))
    }

    struct ShapeError: Error {}

    /// The inner `SBNmJb` payload array a sent request actually carried:
    /// unwraps the form body's `f.req`, then `BatchExecute.request`'s own
    /// envelope (`[[[rpc, payload, null, "generic"]]]`), then the payload
    /// string itself - the exact nesting `BatchExecute.request(_:...)`
    /// builds, read back out rather than re-derived.
    static func innerPayload(of request: HTTPRequest) throws -> [Any] {
        let body = String(decoding: request.body ?? Data(), as: UTF8.self)
        guard let freqField = body.split(separator: "&").first(where: { $0.hasPrefix("f.req=") })
        else { throw ShapeError() }
        let encoded = String(freqField.dropFirst("f.req=".count))
        guard let decoded = encoded.removingPercentEncoding else { throw ShapeError() }
        guard let topLevel = try JSONSerialization.jsonObject(with: Data(decoded.utf8)) as? [Any],
              let middle = topLevel.first as? [Any], let row = middle.first as? [Any], row.count > 1,
              let payloadString = row[1] as? String
        else { throw ShapeError() }
        guard let inner = try JSONSerialization.jsonObject(with: Data(payloadString.utf8)) as? [Any]
        else { throw ShapeError() }
        return inner
    }
}
