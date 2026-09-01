import Foundation
import GChatBridgeCore

/// A scripted `HTTPTransport`, so these tests need no network.
///
/// A near-twin of the core's own fake, duplicated rather than shared because
/// `scripts/test.sh` fails any build where test scaffolding is reachable from
/// shipping code - and exporting the core's version would mean shipping it.
/// Thirty lines of duplication is the cheaper side of that trade.
actor ScriptedTransport: HTTPTransport {
    struct Exhausted: Error {}

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

    private var responses: [Result<HTTPResponse, any Error>]
    private var streams: [Script]
    private(set) var sent: [HTTPRequest] = []

    init(_ responses: [Result<HTTPResponse, any Error>], streams: [Script] = []) {
        self.responses = responses
        self.streams = streams
    }

    static func ok(_ body: String, url: URL? = nil) -> Result<HTTPResponse, any Error> {
        .success(
            HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data(body.utf8), url: url)
        )
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        sent.append(request)
        guard !responses.isEmpty else { throw Exhausted() }
        return try responses.removeFirst().get()
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        sent.append(request)
        guard !streams.isEmpty else { throw Exhausted() }
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
