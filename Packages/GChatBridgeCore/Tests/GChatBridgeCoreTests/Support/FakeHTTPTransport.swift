import Foundation
@testable import GChatBridgeCore

/// A scripted `HTTPTransport`.
///
/// It lives in the test target rather than in `GChatBridgeCoreTestSupport`
/// because nothing outside these tests needs it, and `scripts/test.sh` fails any
/// build where test scaffolding is reachable from shipping code.
///
/// It **refuses to improvise**: once its script runs out it throws rather than
/// repeating the last response or returning a default. A fake that invents
/// answers turns a missing-expectation bug into a passing test.
actor FakeHTTPTransport: HTTPTransport {
    struct Exhausted: Error, CustomStringConvertible {
        let sentCount: Int
        var description: String {
            "FakeHTTPTransport ran out of scripted responses after \(sentCount) request(s)"
        }
    }

    /// One scripted streaming response: a head, then body chunks in order.
    struct Script: Sendable {
        let status: Int
        let headers: HTTPHeaders
        let chunks: [String]

        init(status: Int = 200, headers: HTTPHeaders = HTTPHeaders([]), chunks: [String]) {
            self.status = status
            self.headers = headers
            self.chunks = chunks
        }
    }

    private var responses: [HTTPResponse]
    private var streams: [Script]

    /// Every request that was made, in order, so a test can assert on what the
    /// code under test actually asked for rather than only on what it did with
    /// the answer.
    private(set) var sent: [HTTPRequest] = []

    init(responses: [HTTPResponse] = [], streams: [Script] = []) {
        self.responses = responses
        self.streams = streams
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        sent.append(request)
        guard !responses.isEmpty else { throw Exhausted(sentCount: sent.count) }
        return responses.removeFirst()
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        sent.append(request)
        guard !streams.isEmpty else { throw Exhausted(sentCount: sent.count) }
        let script = streams.removeFirst()
        return HTTPStream(
            status: script.status,
            headers: script.headers,
            body: AsyncThrowingStream { continuation in
                for chunk in script.chunks {
                    continuation.yield(Data(chunk.utf8))
                }
                continuation.finish()
            }
        )
    }
}
