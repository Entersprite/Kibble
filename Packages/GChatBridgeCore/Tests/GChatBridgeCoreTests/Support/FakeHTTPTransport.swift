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

    /// A body that died rather than ended.
    struct Dropped: Error, CustomStringConvertible {
        var description: String {
            "the connection dropped mid-body"
        }
    }

    /// One scripted streaming response: a head, then body chunks in order.
    struct Script: Sendable {
        let status: Int
        let headers: HTTPHeaders
        let chunks: [String]

        /// Whether the body throws after `chunks` instead of finishing.
        ///
        /// The distinction this fake could not express before, and the reason
        /// no test could reach a *successful* reconnect: a body that **ends**
        /// is ordinary (§3.5) and reopens on the same SID, while a body that
        /// **throws** is the dropped socket. Without it every retry died on
        /// the next script being absent rather than on the connection dying,
        /// so the script after a drop was never reached.
        let dropsAfterChunks: Bool

        init(
            status: Int = 200,
            headers: HTTPHeaders = HTTPHeaders([]),
            chunks: [String],
            dropsAfterChunks: Bool = false
        ) {
            self.status = status
            self.headers = headers
            self.chunks = chunks
            self.dropsAfterChunks = dropsAfterChunks
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
                continuation.finish(throwing: script.dropsAfterChunks ? Dropped() : nil)
            }
        )
    }
}
