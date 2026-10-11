import Foundation
import Testing
@testable import GChatBridgeCore

/// `batchexecute` as the web client sends and reads it (`findings.md` §65.6).
@Suite("batchexecute")
struct BatchExecuteTests {
    static let context = BatchExecuteContext(
        token: "TOKEN", sessionID: "-123", buildLabel: "boq_x", language: "en"
    )

    static func form(_ request: HTTPRequest) throws -> [String: String] {
        let body = try String(decoding: #require(request.body), as: UTF8.self)
        #expect(body.hasSuffix("&"))
        var fields: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            fields[parts[0]] = parts[1].removingPercentEncoding
        }
        return fields
    }

    @Test func theRequestHasTheCapturesEnvelope() throws {
        let request = BatchExecute.request(
            rpc: "SBNmJb", payload: #"[null,"a b"]"#, sourcePath: "/app/search",
            context: Self.context, requestID: 100_001, endpoints: ChatEndpoints(),
            sendsExtensionHeader: true
        )
        #expect(request.method == .post)
        #expect(request.url.absoluteString == "https://chat.google.com/_/DynamiteWebUi/data/batchexecute"
            + "?rpcids=SBNmJb&source-path=%2Fapp%2Fsearch&f.sid=-123&bl=boq_x&hl=en"
            + "&soc-app=1&soc-platform=1&soc-device=1&_reqid=100001&rt=c")
        #expect(request.headers["x-same-domain"] == "1")
        #expect(request.headers["content-type"] == "application/x-www-form-urlencoded;charset=UTF-8")
        #expect(request.headers["origin"] == "https://chat.google.com")
        #expect(request.headers[BatchExecute.extensionHeaderName] == BatchExecute.extensionHeaderValue)
        let fields = try Self.form(request)
        #expect(fields["at"] == "TOKEN")
        #expect(fields["f.req"] == #"[[["SBNmJb","[null,\"a b\"]",null,"generic"]]]"#)
    }

    @Test func theExtensionHeaderIsOptional() {
        let request = BatchExecute.request(
            rpc: "SBNmJb", payload: "[]", sourcePath: "/app/search", context: Self.context,
            requestID: 1, endpoints: ChatEndpoints(), sendsExtensionHeader: false
        )
        #expect(request.headers[BatchExecute.extensionHeaderName] == nil)
    }

    /// A length line is not trusted: Google counts it in a unit this parser
    /// does not need to agree with. Frames are found by their brackets, and a
    /// bracket inside a string is not one.
    @Test func framesAreReadPastTheirLengthLines() throws {
        let body = #")]}'"# + "\n\n123\n"
            + #"[["wrb.fr","SBNmJb","[1,\"a]\"]",null,null,null,"generic"],["di",42]]"#
            + "\n25\n" + #"[["e",4,null,null,99]]"# + "\n"
        let answers = try BatchExecute.answers(in: Data(body.utf8))
        #expect(answers == [BatchExecuteAnswer(rpc: "SBNmJb", payload: #"[1,"a]"]"#, errorCode: nil)])
    }

    @Test func anErrorRowCarriesItsCode() throws {
        let body = #")]}'"# + "\n\n50\n" + #"[["wrb.fr","SBNmJb",null,null,null,[3],"generic"]]"# + "\n"
        #expect(try BatchExecute.answers(in: Data(body.utf8))
            == [BatchExecuteAnswer(rpc: "SBNmJb", payload: nil, errorCode: 3)])
    }

    @Test func aPageThatIsNotAnAnswerThrows() {
        #expect(throws: BatchExecuteError.notAnAnswer) {
            try BatchExecute.answers(in: Data("<html>sign in</html>".utf8))
        }
    }

    @Test func anUnclosedFrameThrows() {
        #expect(throws: BatchExecuteError.malformedFrame) {
            try BatchExecute.answers(in: Data(#")]}'\n\n9\n[["wrb.fr""#.utf8))
        }
    }

    /// The fixture's syntax is the real answer's (`findings.md` §65.2).
    @Test func theCapturedAnswerParses() throws {
        let url = try #require(Bundle.module.url(
            forResource: "sbnmjb-answer", withExtension: "txt", subdirectory: "batchexecute"
        ))
        let answers = try BatchExecute.answers(in: Data(contentsOf: url))
        let search = try #require(answers.first { $0.rpc == "SBNmJb" })
        let payload = try #require(search.payload)
        let inner = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [Any])
        #expect((inner[9] as? [Any])?.count == 2)
    }

    /// Committed, so it must carry no content: every string is a shape token.
    @Test func theCapturedAnswerCarriesNoContent() throws {
        let url = try #require(Bundle.module.url(
            forResource: "sbnmjb-answer", withExtension: "txt", subdirectory: "batchexecute"
        ))
        let answers = try BatchExecute.answers(in: Data(contentsOf: url))
        let allowed = /^(str|int)\([0-9]+\)$/
        func strings(_ value: Any) -> [String] {
            switch value {
            case let text as String:
                if let nested = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
                   nested is [Any] {
                    return strings(nested)
                }
                return [text]
            case let list as [Any]: return list.flatMap(strings)
            case let object as [String: Any]: return object.values.flatMap(strings)
            default: return []
            }
        }
        for answer in answers {
            for text in strings(answer.payload as Any) {
                #expect(text.wholeMatch(of: allowed) != nil, "content in the fixture: \(text.count) chars")
            }
        }
    }
}
