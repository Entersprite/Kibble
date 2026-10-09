import Foundation
import GChatBridgeCore
@testable import LocalBridgeBackend

/// Answers the shell, and each `/api/` method by name, from a table; records
/// every request. A method with no answer gets a 500, so a test that forgot
/// one fails loudly rather than reading an empty body as an answer.
actor ThreadCallTransport: HTTPTransport {
    struct NoStream: Error {}

    private var answers: [String: Data]
    /// Methods whose request waits until `answer(_:with:)` supplies a body.
    private var held: Set<String>
    private var waiting: [String: CheckedContinuation<Data, Never>] = [:]
    private(set) var sent: [HTTPRequest] = []

    init(answers: [String: Data], holding held: Set<String> = []) {
        self.answers = answers
        self.held = held
    }

    /// Supplies a body, releasing a held request if one is waiting.
    func answer(_ method: String, with body: Data) {
        held.remove(method)
        if let continuation = waiting.removeValue(forKey: method) {
            continuation.resume(returning: body)
        } else {
            answers[method] = body
        }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        sent.append(request)
        if request.url.path.contains("/mole/world") {
            let html = LocalBridgeBackendTests.shell(app: "DynamiteWebUi")
            return HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data(html.utf8))
        }
        let method = request.url.lastPathComponent
        if held.contains(method) {
            let body = await withCheckedContinuation { waiting[method] = $0 }
            return HTTPResponse(status: 200, headers: HTTPHeaders([]), body: body)
        }
        guard let body = answers[method] else {
            return HTTPResponse(status: 500, headers: HTTPHeaders([]), body: Data())
        }
        return HTTPResponse(status: 200, headers: HTTPHeaders([]), body: body)
    }

    func stream(_: HTTPRequest) async throws -> HTTPStream {
        throw NoStream()
    }

    /// The bodies sent to one method, in order. `HTTPRequest.body` is
    /// optional; every `/api/` call carries one.
    func bodies(of method: String) -> [Data] {
        sent.filter { $0.url.lastPathComponent == method }.compactMap(\.body)
    }
}
