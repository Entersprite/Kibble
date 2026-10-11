import Foundation

/// What a `batchexecute` call needs from the page (`findings.md` §65.6).
public struct BatchExecuteContext: Sendable, Hashable {
    /// The `at` form field. Not `/api/`'s token (§65.4).
    public let token: String
    /// `f.sid`.
    public let sessionID: String
    /// `bl`, the server's build label.
    public let buildLabel: String
    /// `hl`.
    public let language: String

    public init(token: String, sessionID: String, buildLabel: String, language: String) {
        self.token = token
        self.sessionID = sessionID
        self.buildLabel = buildLabel
        self.language = language
    }

    /// `nil` when the shell lacks any of the three.
    public init?(_ wiz: WizGlobalData, language: String = "en") {
        guard let token = wiz.batchToken, let sessionID = wiz.sessionID, let buildLabel = wiz.buildLabel
        else { return nil }
        self.init(token: token, sessionID: sessionID, buildLabel: buildLabel, language: language)
    }
}

/// One `wrb.fr` row of an answer.
public struct BatchExecuteAnswer: Sendable, Hashable {
    public let rpc: String
    /// The answer, still a JSON string, as the wire nests it; `nil` when the
    /// row carried none.
    public let payload: String?
    /// The code at row position 5, when the row carried one (`[Verify]`: seen
    /// in other Google apps' errors, not yet in Chat's).
    public let errorCode: Int?

    public init(rpc: String, payload: String?, errorCode: Int?) {
        self.rpc = rpc
        self.payload = payload
        self.errorCode = errorCode
    }
}

public enum BatchExecuteError: Error, Equatable {
    /// The body does not start with `)]}'`: a sign-in page, an HTML error.
    case notAnAnswer
    /// A frame opened and never closed.
    case malformedFrame
}

/// Chat on the web's `batchexecute` (`findings.md` §65.6): Kibble's only call
/// outside the `/api/` family on `chat.google.com`. The one place its URL is
/// spelled.
public enum BatchExecute {
    static let path = "/_/DynamiteWebUi/data/batchexecute"

    /// A constant the web client sends on every call: an array of small
    /// numbers, feature flags `[Verify]` (§65.6). Optional, so the probe can
    /// say whether it matters.
    public static let extensionHeaderName = "x-goog-ext-348566919-jspb"
    public static let extensionHeaderValue = "[null,3,[null,null,null,null,2,2,2,2,2,2,null,null,null,null,"
        + "null,2,2,2,2,2,null,2,2,2,2,2,2,null,2,2,null,2,2,null,null,2,2,2,null,2,2,null,2,2,null,2,2,2,2,"
        + "2,2,null,2,2,2,2,2,2,null,2,null,2,null,2,2,2,2,null,2,0,null,2,2,0,0,0]]"

    // swiftlint:disable function_parameter_count
    /// One RPC, `rt=c`, as the capture sent it: parameters in its order, the
    /// form's trailing `&` included.
    ///
    /// Seven parameters, past swiftlint's `function_parameter_count` ceiling:
    /// this is the task plan's own interface, consumed verbatim by its caller,
    /// so unlike the codebase's other reductions (a context struct instead of
    /// a disable) there is no internal grouping that would not just move the
    /// seven arguments into a struct literal at every call site instead.
    public static func request(
        rpc: String,
        payload: String,
        sourcePath: String,
        context: BatchExecuteContext,
        requestID: Int,
        endpoints: ChatEndpoints,
        sendsExtensionHeader: Bool
    ) -> HTTPRequest {
        let query = QueryEncoding.query([
            ("rpcids", rpc), ("source-path", sourcePath), ("f.sid", context.sessionID),
            ("bl", context.buildLabel), ("hl", context.language), ("soc-app", "1"),
            ("soc-platform", "1"), ("soc-device", "1"), ("_reqid", String(requestID)), ("rt", "c")
        ])
        let host = endpoints.host.absoluteString.hasSuffix("/")
            ? String(endpoints.host.absoluteString.dropLast()) : endpoints.host.absoluteString
        // Force-unwrapped: every piece is either a constant or percent-encoded.
        let url = URL(string: host + path + "?" + query)!
        let envelope: [Any] = [[[rpc, payload, NSNull(), "generic"]]]
        let freq = (try? JSONSerialization.data(withJSONObject: envelope, options: [.withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        let body = "f.req=\(QueryEncoding.encode(freq))&at=\(QueryEncoding.encode(context.token))&"
        var headers: [(String, String)] = [
            ("content-type", "application/x-www-form-urlencoded;charset=UTF-8"),
            ("x-same-domain", "1"),
            ("origin", host),
            ("user-agent", endpoints.userAgent)
        ]
        if sendsExtensionHeader {
            headers.append((extensionHeaderName, extensionHeaderValue))
        }
        return HTTPRequest(
            method: .post, url: url, headers: HTTPHeaders(headers), body: Data(body.utf8),
            timeout: .seconds(30), traceLabel: "batchexecute \(rpc)"
        )
    }

    // swiftlint:enable function_parameter_count

    /// Every `wrb.fr` row in an `rt=c` answer. The length lines are skipped,
    /// not trusted: each frame is found by its balanced brackets, strings
    /// skipped, as `WizGlobalData` finds its object.
    public static func answers(in body: Data) throws -> [BatchExecuteAnswer] {
        let text = String(decoding: body, as: UTF8.self)
        guard text.hasPrefix(")]}'") else { throw BatchExecuteError.notAnAnswer }
        var answers: [BatchExecuteAnswer] = []
        var cursor = text.index(text.startIndex, offsetBy: 4)
        while let open = text[cursor...].firstIndex(of: "[") {
            guard let close = closingBracket(in: text, from: open)
            else { throw BatchExecuteError.malformedFrame }
            let rows = (try? JSONSerialization.jsonObject(with: Data(text[open ... close].utf8))) as? [Any] ??
                []
            for case let row as [Any] in rows {
                guard row.first as? String == "wrb.fr", row.count > 1,
                      let rpc = row[1] as? String else { continue }
                answers.append(BatchExecuteAnswer(
                    rpc: rpc,
                    payload: row.count > 2 ? row[2] as? String : nil,
                    errorCode: row.count > 5 ? (row[5] as? [Any])?.first as? Int : nil
                ))
            }
            cursor = text.index(after: close)
        }
        return answers
    }

    private static func closingBracket(in text: String, from open: String.Index) -> String.Index? {
        var depth = 0
        var insideString = false
        var escaped = false
        for index in text.indices[open...] {
            let character = text[index]
            if escaped {
                escaped = false
                continue
            }
            switch character {
            case "\\" where insideString: escaped = true
            case "\"": insideString.toggle()
            case "[" where !insideString: depth += 1
            case "]" where !insideString:
                depth -= 1
                if depth == 0 {
                    return index
                }
            default: break
            }
        }
        return nil
    }
}
