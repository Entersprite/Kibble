import Foundation
import GChatBridgeCore
import URLSessionTransport

/// The three things every `SBNmJb` call needs, grouped so `send` and its
/// callers stay under swiftlint's `function_parameter_count` ceiling - the
/// same reason `BatchExecuteCall` groups its own three. A class, not a
/// struct: every call shares one incrementing request id.
private final class SearchCallContext {
    let client: PunctualClient
    let context: BatchExecuteContext
    let endpoints: ChatEndpoints
    private var requestID: Int

    init(client: PunctualClient, context: BatchExecuteContext, endpoints: ChatEndpoints) {
        self.client = client
        self.context = context
        self.endpoints = endpoints
        requestID = Int.random(in: 1000 ... 9999)
    }

    func nextRequestID() -> Int {
        requestID += 100_000
        return requestID
    }
}

/// `--probe=search`: can Kibble run Chat on the web's message search
/// (`findings.md` §65)? Reads only: one search, a second page, the newest-first
/// order. **Shapes, counts and lengths, never a value**: the query is the
/// owner's and is reported by length; every string in an answer by length.
public enum SearchProbeReport {
    /// A common word, so the account has hits. `--probe-query=` overrides.
    public static let defaultQuery = "the"

    public static func run(
        store: KeychainCredentialStore = KeychainCredentialStore(),
        transport: any HTTPTransport = URLSessionTransport(),
        endpoints: ChatEndpoints = ChatEndpoints(),
        query: String = defaultQuery,
        flush: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> String {
        var lines = ["search probe (findings.md §65)", "query: \(query.count) chars", ""]
        func done() -> String {
            let text = lines.joined(separator: "\n")
            flush(text)
            return text
        }
        flush(lines.joined(separator: "\n"))
        guard let cookies = await APIProbeReport.appendCredential(store: store, lines: &lines)
        else { return done() }
        guard let bootstrapped = await APIProbeReport.appendBootstrap(
            cookies: cookies, store: store, transport: transport, endpoints: endpoints, lines: &lines
        ) else { return done() }
        guard let context = appendWizValues(bootstrapped.wiz, lines: &lines) else { return done() }
        flush(lines.joined(separator: "\n"))
        let call = SearchCallContext(
            client: PunctualClient(transport: transport, credentials: bootstrapped.credentials),
            context: context, endpoints: endpoints
        )
        await appendSearches(query: query, call: call, lines: &lines, flush: flush)
        return done()
    }

    /// The page's shell values `BatchExecuteContext` needs, and the keys that
    /// might carry `at` (42 chars in a capture, §65.4) when it does not.
    /// `nil` once "the shell lacks" has been appended.
    private static func appendWizValues(_ wiz: WizGlobalData, lines: inout [String]) -> BatchExecuteContext? {
        lines.append("")
        lines.append("page values: \(wiz)")
        let fortyTwo = wiz.stringLengths.filter { $0.value == 42 }.keys.sorted()
        lines.append("keys holding a 42-char string (at's length, §65.4): \(fortyTwo)")
        guard let context = BatchExecuteContext(wiz) else {
            lines.append("STOP: the shell lacks SNlM0e, FdrFJe or cfb2h; see the keys above")
            return nil
        }
        return context
    }

    /// One query id for the whole run, a search, its second page, then a
    /// newest-first search of the same text under a fresh query id (§65.2).
    private static func appendSearches(
        query: String, call: SearchCallContext, lines: inout [String], flush: (String) -> Void
    ) async {
        let queryID = SearchRequests.newQueryID()
        // Rungs: the captured unknowns left out, then the header added.
        var first = await send(
            MessageSearchPayload(text: query, queryID: queryID), header: false, label: "rung A",
            call: call, lines: &lines
        )
        flush(lines.joined(separator: "\n"))
        if first == nil {
            first = await send(
                MessageSearchPayload(text: query, queryID: queryID), header: true, label: "rung B",
                call: call, lines: &lines
            )
            flush(lines.joined(separator: "\n"))
        }
        guard let first else {
            lines.append("STOP: no rung answered a payload")
            return
        }
        let hits = (first.count > 9 ? first[9] as? [Any] : nil) ?? []
        lines.append("")
        lines.append("hits: \(hits.count); next token: \((first.first as? String)?.count ?? 0) chars")
        appendHits(hits, lines: &lines)
        flush(lines.joined(separator: "\n"))
        await appendSecondPage(after: first, query: query, queryID: queryID, call: call, lines: &lines)
        await appendNewestFirst(query: query, call: call, lines: &lines)
    }

    /// The second page, when the first answered a token, and its hit count.
    private static func appendSecondPage(
        after first: [Any], query: String, queryID: String, call: SearchCallContext, lines: inout [String]
    ) async {
        guard let token = first.first as? String else { return }
        let second = await send(
            MessageSearchPayload(
                text: query, queryID: queryID, pageToken: token,
                clientMillis: Int64(Date().timeIntervalSince1970 * 1000)
            ),
            header: false, label: "page 2", call: call, lines: &lines
        )
        let count = (second?.count ?? 0) > 9 ? (second?[9] as? [Any])?.count ?? 0 : 0
        lines.append("page 2 hits: \(count)")
    }

    /// A fresh query, newest first, checked for its hits' own times descending.
    private static func appendNewestFirst(
        query: String, call: SearchCallContext, lines: inout [String]
    ) async {
        let newest = await send(
            MessageSearchPayload(text: query, queryID: SearchRequests.newQueryID(), newestFirst: true),
            header: false, label: "newest first", call: call, lines: &lines
        )
        guard let newest, newest.count > 9, let newestHits = newest[9] as? [Any] else { return }
        let times = newestHits.compactMap { decodedMessage($0)?.createTime }
        let descending = times == times.sorted(by: >)
        lines.append("newest first: \(times.count) decoded times, descending: \(descending)")
    }

    /// One `SBNmJb` call. `nil` once its failure, or the absence of its row
    /// or payload, has been appended.
    private static func send(
        _ payload: MessageSearchPayload, header: Bool, label: String, call: SearchCallContext,
        lines: inout [String]
    ) async -> [Any]? {
        let requestID = call.nextRequestID()
        let request = BatchExecute.request(
            BatchExecuteCall(
                rpc: SearchRequests.rpc, payload: SearchRequests.payload(payload),
                sourcePath: SearchRequests.sourcePath
            ),
            context: call.context, requestID: requestID, endpoints: call.endpoints,
            sendsExtensionHeader: header
        )
        do {
            let client = call.client
            let response = try await client.send(request)
            lines.append("\(label): HTTP \(response.status), \(response.body.count) bytes")
            let answers = try BatchExecute.answers(in: response.body)
            guard let answer = answers.first(where: { $0.rpc == SearchRequests.rpc }) else {
                lines.append("  no SBNmJb row; rows: \(answers.map(\.rpc))")
                return nil
            }
            lines.append("  error code: \(answer.errorCode.map(String.init) ?? "none")")
            guard let payload = answer.payload,
                  let inner = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [Any]
            else {
                lines.append("  no payload")
                return nil
            }
            lines.append("  answer: \(shape(of: inner, depth: 1))")
            return inner
        } catch {
            lines.append("\(label): failed, \(APIProbeReport.safeDescription(of: error))")
            return nil
        }
    }

    /// For each of the first three hits: its top-level shape, then whether it,
    /// or any list inside it at depth one, decodes as a `Message` with an id,
    /// a time and text. The hit may be a wrapper (§65.2).
    static func appendHits(_ hits: [Any], lines: inout [String]) {
        for (number, hit) in hits.prefix(3).enumerated() {
            lines.append("hit \(number): \(shape(of: hit, depth: 1))")
            for (place, value) in candidates(for: hit) {
                guard let message = decodedMessage(value) else { continue }
                lines.append("  \(place) as Message: " + messageShapeLine(message))
            }
        }
    }

    /// A hit, plus every list it directly contains, each labeled by place.
    private static func candidates(for hit: Any) -> [(String, Any)] {
        var candidates: [(String, Any)] = [("itself", hit)]
        if let list = hit as? [Any] {
            candidates += list.enumerated().compactMap { offset, element in
                element is [Any] ? ("[\(offset)]", element) : nil
            }
        }
        return candidates
    }

    /// Lengths and flags only - never the id, time or text themselves.
    private static func messageShapeLine(_ message: GChatBridgeCore.Message) -> String {
        let id = message.id.messageID.count
        let topic = message.id.parentID.topicID.topicID.count
        let groupSet = message.id.parentID.topicID.hasGroupID
        let time = String(message.createTime).count
        let text = message.textBody.count
        let sender = message.creator.userID.id.count
        let types = message.annotations.map(\.type.rawValue)
        return "id \(id) chars, topic \(topic) chars, group set \(groupSet), "
            + "time \(time) digits, text \(text) chars, sender \(sender) chars, "
            + "annotations \(message.annotations.count) (types \(types)), "
            + "field 34 \(message.hasIsInlineReply)"
    }

    /// A `Message` with an id and a time, or `nil`.
    static func decodedMessage(_ value: Any) -> GChatBridgeCore.Message? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let decoded = try? PBLiteDecoder.decode(GChatBridgeCore.Message.self, fromJSON: data).message,
              !decoded.id.messageID.isEmpty, decoded.createTime > 0
        else { return nil }
        return decoded
    }

    /// Every string as `s<length>`, numbers of six digits or more as
    /// `n<digits>d`, lists below `depth` as `<list N>`. Parsed, never a window
    /// of text (session 36).
    static func shape(of value: Any, depth: Int) -> String {
        switch value {
        case let text as String:
            return "s\(text.count)"
        case is NSNull:
            return "null"
        case let number as NSNumber:
            let digits = String(describing: number)
            return digits.count >= 6 ? "n\(digits.count)d" : digits
        case let list as [Any]:
            guard depth > 0 else { return "<list \(list.count)>" }
            return "[" + list.map { shape(of: $0, depth: depth - 1) }.joined(separator: ", ") + "]"
        case let object as [String: Any]:
            guard depth > 0 else { return "<object \(object.count)>" }
            return "{" + object.keys.sorted().map { "\($0): \(shape(of: object[$0]!, depth: depth - 1))" }
                .joined(separator: ", ") + "}"
        default:
            return "?"
        }
    }
}
